import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Owns the gpu-screen-recorder process and publishes live state through
// PluginGlobalVar, so the bar pill, the control center tile, the detail panel
// and the settings page all read the same recording.
PluginComponent {
    id: root

    readonly property var log: Log.scoped("dankRecorder")

    // ── Settings, read live from pluginData ────────────────────────────────
    readonly property string captureTarget: pluginData.captureTarget || "focused"
    readonly property string monitorName: (pluginData.monitor || "").trim()
    readonly property string quality: pluginData.quality || "very_high"
    readonly property string codec: pluginData.codec || "h264"
    readonly property string container: pluginData.container || "mp4"
    readonly property bool recordCursor: pluginData.recordCursor !== false
    readonly property string audioSource: pluginData.audioSource || "output"
    readonly property string encoderMode: pluginData.encoderMode || "auto"
    readonly property string gpuPreference: pluginData.gpuPreference || "auto"
    readonly property bool lowPower: pluginData.lowPower === true
    readonly property bool notify: pluginData.notify !== false
    readonly property string customOutputDir: (pluginData.outputDir || "").trim()
    readonly property bool confirmBeforeStart: pluginData.confirmBeforeStart !== false
    readonly property real overlayX: pluginData.overlayX !== undefined ? pluginData.overlayX : -1
    readonly property real overlayY: pluginData.overlayY !== undefined ? pluginData.overlayY : -1

    readonly property int fps: {
        const v = parseInt(pluginData.fps || "60", 10);
        return (v === 30 || v === 60 || v === 120) ? v : 60;
    }

    readonly property string outputDir: {
        if (customOutputDir)
            return customOutputDir;
        const videos = Quickshell.env("XDG_VIDEOS_DIR");
        if (videos)
            return videos + "/Screencasts";
        return (Quickshell.env("HOME") || "/tmp") + "/Videos/Screencasts";
    }

    readonly property string audioArg: {
        switch (audioSource) {
        case "output": return "default_output";
        case "input": return "default_input";
        case "both": return "default_output|default_input";
        default: return "";
        }
    }

    // Audio follows the Audio setting. The canvas bar can mute and unmute
    // without losing the source chosen in the settings.
    readonly property bool audioOn: audioSource !== "none"
    readonly property string audioLastSource: pluginData.audioSourceLast || "output"

    readonly property string audioText: {
        switch (audioSource) {
        case "none": return I18n.trFor("dankRecorder", "Muted");
        case "both": return I18n.trFor("dankRecorder", "Audio + mic");
        case "input": return I18n.trFor("dankRecorder", "Microphone");
        default: return I18n.trFor("dankRecorder", "Sound");
        }
    }

    readonly property string audioIcon: {
        switch (audioSource) {
        case "none": return "volume_off";
        case "input": return "mic";
        case "both": return "settings_voice";
        default: return "volume_up";
        }
    }

    function toggleAudio() {
        if (!pluginService)
            return "unavailable";
        if (audioOn) {
            pluginService.savePluginData("dankRecorder", "audioSourceLast", audioSource);
            pluginService.savePluginData("dankRecorder", "audioSource", "none");
            return "muted";
        }
        pluginService.savePluginData("dankRecorder", "audioSource",
                                     audioLastSource === "none" ? "output" : audioLastSource);
        return "sound";
    }

    // ── State shared with every surface ────────────────────────────────────
    PluginGlobalVar { id: stateVar; varName: "state"; defaultValue: "idle" }
    PluginGlobalVar { id: elapsedVar; varName: "elapsed"; defaultValue: 0 }
    PluginGlobalVar { id: backendVar; varName: "backend"; defaultValue: "" }
    PluginGlobalVar { id: lastFileVar; varName: "lastFile"; defaultValue: "" }
    PluginGlobalVar { id: errorVar; varName: "error"; defaultValue: "" }
    PluginGlobalVar { id: gpusVar; varName: "gpus"; defaultValue: "" }
    PluginGlobalVar { id: capsVar; varName: "caps"; defaultValue: "" }
    PluginGlobalVar { id: canvasVar; varName: "canvas"; defaultValue: "" }

    readonly property string state: stateVar.value || "idle"

    readonly property bool armed: state === "armed"

    // ── Internals ──────────────────────────────────────────────────────────
    property var _gpus: []
    property var _hardwareCodecs: []
    property string _infoVendor: ""
    property string _armedSource: ""
    property string _armedRegion: ""
    property var _armedScreen: null
    readonly property bool _armedIsRegion: _armedSource === "region"
    property var _target: ({})
    property var _candidates: []
    property int _candidateIndex: 0
    property int _requestId: 0
    property string _pendingFile: ""
    property int _pid: 0
    property bool _stopping: false
    property string _stdoutText: ""
    property string _stderrText: ""

    // ── Notifications ──────────────────────────────────────────────────────
    function _notifyInfo(message, details) {
        if (notify)
            ToastService.showInfo(I18n.trFor("dankRecorder", message), details || "");
    }

    function _notifyWarn(message, details) {
        ToastService.showWarning(I18n.trFor("dankRecorder", message), details || "");
    }

    function _notifyError(message, details) {
        ToastService.showError(I18n.trFor("dankRecorder", message), details || "");
    }

    // ── GPU inventory ──────────────────────────────────────────────────────
    // Prints one line per DRM render node: <pci>| <vendor:device>| <render node>.
    readonly property string gpuProbeCommand: "for n in /dev/dri/by-path/pci-*-render; do "
        + "[ -e \"$n\" ] || continue; "
        + "b=$(basename \"$n\"); pci=${b#pci-}; pci=${pci%-render}; "
        + "vid=$(cat \"/sys/bus/pci/devices/$pci/vendor\" 2>/dev/null); "
        + "did=$(cat \"/sys/bus/pci/devices/$pci/device\" 2>/dev/null); "
        + "echo \"$b|${vid#0x}:${did#0x}|$(basename $(readlink -f \"$n\"))\"; "
        + "done"

    function _gpuLabel(vendorId) {
        switch (String(vendorId).toLowerCase()) {
        case "1002": return "AMD";
        case "10de": return "NVIDIA";
        case "8086": return "Intel";
        default: return "GPU " + vendorId;
        }
    }

    function detectGpus() {
        Proc.runCommand("dankRecorder.gpus", ["sh", "-c", gpuProbeCommand], (output, exitCode) => {
            const found = [];
            const lines = (output || "").trim().split("\n");
            for (const line of lines) {
                const parts = line.split("|");
                if (parts.length < 3 || !parts[1])
                    continue;
                const ids = parts[1].split(":");
                found.push({
                    "pci": parts[0],
                    "vendor": ids[0],
                    "device": ids[1],
                    "node": parts[2],
                    "label": _gpuLabel(ids[0])
                });
            }
            root._gpus = found;
            const summary = found.map(g => g.label + " (" + g.vendor + ":" + g.device + ")");
            gpusVar.set(summary.join(", ") || I18n.trFor("dankRecorder", "none detected"));
        }, 0, 5000);
    }

    // ── Encoder capabilities ───────────────────────────────────────────────
    // gpu-screen-recorder --info reports the GPU that drives the display and the
    // codecs that GPU can encode. Fedora reports only h264_software until the
    // RPM Fusion VAAPI drivers replace the stock Mesa ones.
    function detectCapabilities() {
        Proc.runCommand("dankRecorder.caps", ["gpu-screen-recorder", "--info"], (output, exitCode) => {
            const codecs = [];
            let vendor = "";
            let section = "";
            for (const raw of (output || "").split("\n")) {
                const line = raw.trim();
                if (!line)
                    continue;
                if (line.startsWith("section=")) {
                    section = line.substring(8);
                    continue;
                }
                if (section === "gpu_info" && line.startsWith("vendor|")) {
                    vendor = line.substring(7);
                } else if (section === "video_codecs" && line.indexOf("|") === -1) {
                    if (!line.endsWith("_software"))
                        codecs.push(line);
                }
            }
            root._hardwareCodecs = codecs;
            root._infoVendor = vendor;
            capsVar.set(codecs.length > 0
                ? _vendorName(vendor) + " · " + codecs.join(", ")
                : I18n.trFor("dankRecorder", "no hardware encoder (CPU only)"));
        }, 0, 5000);
    }

    function _vendorName(vendor) {
        switch (vendor) {
        case "nvidia": return "NVIDIA";
        case "intel": return "Intel";
        case "amd": return "AMD";
        default: return "GPU";
        }
    }

    function _encoderKind(vendor) {
        switch (vendor) {
        case "nvidia": return "NVENC";
        case "intel": return "Quick Sync";
        default: return "VAAPI";
        }
    }

    // The live encoder label. The real encoder is confirmed from the encoder
    // log line when the recording stops.
    function _expectedBackend() {
        if (encoderMode === "cpu")
            return "CPU (x264)";
        if (_hardwareCodecs.indexOf(codec) === -1)
            return "CPU (no " + codec + " GPU encoder)";
        return _vendorName(_infoVendor) + " GPU (" + _encoderKind(_infoVendor) + ", " + codec + ")";
    }

    // Environment that pins the preferred GPU. gpu-screen-recorder encodes on
    // the GPU that drives the captured monitor, so DRI_PRIME is best effort: if
    // the device is missing or its encoder fails, the candidate chain below
    // retries without it and finally on the CPU.
    function _preferredGpu() {
        const wanted = {"amd": "1002", "nvidia": "10de", "intel": "8086"}[gpuPreference];
        if (!wanted)
            return null;
        for (const gpu of _gpus) {
            if (gpu.vendor === wanted)
                return gpu;
        }
        return null;
    }

    // ── Capture target resolution ──────────────────────────────────────────
    function _nextRequest() {
        _requestId += 1;
        return _requestId;
    }

    function _isCurrentRequest(requestId) {
        return requestId === _requestId;
    }

    function _launch(source, region) {
        const requestId = _nextRequest();
        _target = {"source": source, "region": region || ""};
        const file = outputDir + "/" + _timestamp() + "." + container;
        stateVar.set("resolving");
        Proc.runCommand("dankRecorder.mkdir", ["mkdir", "-p", outputDir], (output, exitCode) => {
            if (!_isCurrentRequest(requestId) || state !== "resolving")
                return;
            if (exitCode !== 0) {
                stateVar.set("idle");
                _notifyError("Cannot create the recording folder", outputDir);
                return;
            }
            _pendingFile = file;
            _candidates = _buildCandidates(_target, file);
            _candidateIndex = 0;
            _startCandidate();
        }, 0, 5000);
    }

    function begin(modeOverride) {
        if (state === "armed") {
            _notifyInfo("Confirm or cancel the pending recording first");
            return "armed";
        }
        if (state !== "idle") {
            _notifyInfo("A recording is already in progress");
            return "busy";
        }
        errorVar.set("");
        const mode = modeOverride || captureTarget;
        const requestId = _nextRequest();
        stateVar.set("resolving");

        if (mode === "region") {
            _selectRegion(requestId);
            return "selecting";
        }
        if (mode === "portal")
            return _arm("portal", "");
        if (mode === "primary")
            return _arm("screen", "");
        if (mode === "monitor" && monitorName)
            return _arm(monitorName, "");
        _resolveFocusedOutput(requestId);
        return "started";
    }

    function _selectRegion(requestId, commandId) {
        // gpu-screen-recorder -region wants WxH+X+Y, which is slurp's -f format.
        // slurp reads stdin, and the shell keeps the child's stdin pipe open, so
        // point stdin at /dev/null or slurp blocks before it draws its overlay.
        Proc.runCommand(commandId || "dankRecorder.slurp",
                        ["sh", "-c", "exec slurp -f '%wx%h+%x+%y' </dev/null"], (output, exitCode) => {
            if (!_isCurrentRequest(requestId))
                return;
            const region = (output || "").trim();
            if (exitCode !== 0 || !region) {
                if (state === "resolving")
                    stateVar.set("idle");
                root._notifyInfo("Region selection cancelled");
                return;
            }
            root._arm("region", region);
        }, 0, 60000);
    }

    // Arm the recorder and show the confirmation bar. When confirmation is off,
    // start at once.
    function _arm(source, region) {
        if (!confirmBeforeStart) {
            _launch(source, region);
            return "started";
        }
        _armedSource = source;
        _armedRegion = region || "";
        _armedScreen = _armedRegion ? _screenForRegion(_armedRegion) : _focusedScreen();
        canvasVar.set(_canvasLabel(source, _armedRegion));
        stateVar.set("armed");
        return "armed";
    }

    function confirmStart() {
        if (state !== "armed")
            return "not_armed";
        const source = _armedSource;
        const region = _armedRegion;
        canvasVar.set("");
        _launch(source, region);
        return "started";
    }

    function cancelArmed() {
        if (state !== "armed")
            return "not_armed";
        _nextRequest();
        stateVar.set("idle");
        canvasVar.set("");
        _notifyInfo("Recording cancelled");
        return "cancelled";
    }

    function reselectRegion() {
        if (state !== "armed")
            return "not_armed";
        _selectRegion(_nextRequest(), "dankRecorder.slurpReselect");
        return "selecting";
    }

    function useFullScreen() {
        if (state !== "armed")
            return "not_armed";
        _nextRequest();
        return _arm("screen", "");
    }

    function _canvasLabel(source, region) {
        if (region) {
            const m = /^(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$/.exec(region);
            if (m)
                return m[1] + " × " + m[2] + "  at " + m[3] + ", " + m[4];
            return region;
        }
        const screen = _focusedScreen();
        const size = screen ? "  " + screen.width + " × " + screen.height : "";
        return (source === "screen" || source === "portal" ? "Full screen" : source) + size;
    }

    function _focusedScreen() {
        const focused = CompositorService.getFocusedScreen();
        if (focused)
            return focused;
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }

    function _screenForRegion(region) {
        const m = /^(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$/.exec(region);
        if (!m)
            return _focusedScreen();
        const cx = parseInt(m[3], 10) + parseInt(m[1], 10) / 2;
        const cy = parseInt(m[4], 10) + parseInt(m[2], 10) / 2;
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const s = Quickshell.screens[i];
            if (cx >= s.x && cx < s.x + s.width && cy >= s.y && cy < s.y + s.height)
                return s;
        }
        return _focusedScreen();
    }

    // Prefer the compositor's focused output; fall back to the first monitor
    // gpu-screen-recorder reports, then to its generic "screen" source.
    function _resolveFocusedOutput(requestId) {
        Proc.runCommand("dankRecorder.focused", ["niri", "msg", "--json", "focused-output"], (output, exitCode) => {
            if (!_isCurrentRequest(requestId) || state !== "resolving")
                return;
            let name = "";
            if (exitCode === 0) {
                try {
                    name = JSON.parse((output || "").trim()).name || "";
                } catch (e) {
                    name = "";
                }
            }
            if (name) {
                root._arm(name, "");
                return;
            }
            Proc.runCommand("dankRecorder.monitors", ["gpu-screen-recorder", "--list-monitors"], (listOutput, listCode) => {
                if (!_isCurrentRequest(requestId) || state !== "resolving")
                    return;
                const first = ((listOutput || "").trim().split("\n")[0] || "").split("|")[0].trim();
                root._arm(first || "screen", "");
            }, 0, 5000);
        }, 0, 5000);
    }

    function _timestamp() {
        const d = new Date();
        const pad = n => (n < 10 ? "0" : "") + n;
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
            + "_" + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds());
    }

    // ── Command candidates ─────────────────────────────────────────────────
    function _buildCandidates(target, file) {
        const common = ["gpu-screen-recorder", "-w", target.source];
        if (target.region)
            common.push("-region", target.region);
        common.push("-f", String(fps), "-k", codec, "-c", container, "-cr", "limited",
                    "-cursor", recordCursor ? "yes" : "no", "-q", quality, "-v", "no");
        if (audioArg)
            common.push("-a", audioArg);
        if (lowPower)
            common.push("-low-power", "yes");
        common.push("-o", file);

        if (encoderMode === "cpu")
            return [{"command": common.concat(["-encoder", "cpu"]), "env": {}, "file": file}];

        const list = [];
        const gpu = _preferredGpu();
        if (gpu) {
            list.push({
                "command": common.concat(["-fallback-cpu-encoding", "yes"]),
                "env": {"DRI_PRIME": gpu.vendor + ":" + gpu.device},
                "file": file
            });
        }
        // Always present: let gpu-screen-recorder pick the GPU that drives the
        // monitor, then let it drop to the CPU encoder if no GPU encoder works.
        list.push({
            "command": common.concat(["-fallback-cpu-encoding", "yes"]),
            "env": {},
            "file": file
        });
        return list;
    }

    // ── Process control ────────────────────────────────────────────────────
    function _startCandidate() {
        const candidate = _candidates[_candidateIndex];
        _pendingFile = candidate.file;
        _stdoutText = "";
        _stderrText = "";
        _stopping = false;
        stateVar.set("starting");
        recorder.environment = candidate.env;
        recorder.command = candidate.command;
        recorder.running = true;
        probeTimer.restart();
    }

    function _handleStarted() {
        _pid = recorder.processId || 0;
        if (_stopping && _pid > 0)
            _signal("SIGINT");
    }

    function _handleExit(exitCode, exitStatus) {
        probeTimer.stop();
        if (_stopping || root.state === "stopping") {
            _finishStop(exitCode);
            return;
        }
        if (root.state === "starting") {
            _advance(exitCode);
            return;
        }
        const wasRecording = (root.state === "recording" || root.state === "paused");
        elapsedTimer.stop();
        stateVar.set("idle");
        if (wasRecording) {
            const detail = _tail() || ("gpu-screen-recorder exited with code " + exitCode);
            errorVar.set(detail);
            _notifyError("Recording stopped unexpectedly", detail);
        }
    }

    function _advance(exitCode) {
        _candidateIndex += 1;
        if (_candidateIndex < _candidates.length)
            _startCandidate();
        else
            _failStart(exitCode);
    }

    function _failStart(exitCode) {
        stateVar.set("idle");
        const detail = _tail() || ("gpu-screen-recorder exited with code " + exitCode);
        errorVar.set(detail);
        _notifyError("Could not start recording", detail);
    }

    function _finishStop(exitCode) {
        _stopping = false;
        stopTimer.stop();
        killTimer.stop();
        probeTimer.stop();
        elapsedTimer.stop();
        stateVar.set("idle");
        elapsedVar.set(0);
        _pid = 0;
        if (_stdoutText || _stderrText)
            _refineBackend();
        const file = _pendingFile;
        if (!file) {
            _notifyWarn("Recording stopped", "No file was written");
            return;
        }
        // The process can exit before it writes anything when it fails during
        // startup, so confirm the file exists before claiming it was saved.
        Proc.runCommand("dankRecorder.checkFile", ["test", "-f", file], (output, code) => {
            if (code === 0) {
                lastFileVar.set(file);
                root._notifyInfo("Recording saved", file);
            } else {
                root._notifyWarn("Recording stopped", "No file was written");
            }
        }, 0, 5000);
    }

    function stop() {
        if (state === "armed")
            return cancelArmed();
        if (state === "idle")
            return "not_recording";
        if (state === "resolving") {
            _nextRequest();
            stateVar.set("idle");
            _notifyInfo("Recording cancelled");
            return "cancelled";
        }
        if (state === "stopping")
            return "stopping";
        _stopping = true;
        stateVar.set("stopping");
        elapsedTimer.stop();
        if (_pid > 0)
            _signal("SIGINT");
        stopTimer.restart();
        return "stopping";
    }

    function toggle() {
        if (state === "idle")
            return begin("");
        return stop();
    }

    function togglePause() {
        if (state === "recording") {
            _signal("SIGUSR2");
            stateVar.set("paused");
            elapsedTimer.stop();
            _notifyInfo("Recording paused");
            return "paused";
        }
        if (state === "paused") {
            _signal("SIGUSR2");
            stateVar.set("recording");
            elapsedTimer.start();
            _notifyInfo("Recording resumed");
            return "recording";
        }
        return "not_recording";
    }

    function _signal(name) {
        if (_pid > 0)
            Quickshell.execDetached(["kill", "-" + name, String(_pid)]);
    }

    function _tail() {
        const text = (_stderrText + "\n" + _stdoutText).trim();
        if (!text)
            return "";
        const lines = text.split("\n").filter(line => line.trim().length > 0);
        return lines.slice(-3).join("\n");
    }

    function _refineBackend() {
        const text = ((_stderrText || "") + "\n" + (_stdoutText || "")).toLowerCase();
        if (text.indexOf("trying cpu encoding") !== -1 || text.indexOf("cpu encoding instead") !== -1 || text.indexOf("libx264") !== -1) {
            backendVar.set("CPU (fallback)");
        } else if (text.indexOf("nvenc") !== -1) {
            backendVar.set("NVIDIA GPU (NVENC)");
        } else if (text.indexOf("vaapi") !== -1) {
            backendVar.set(_vendorName(_infoVendor) + " GPU (" + _encoderKind(_infoVendor) + ")");
        } else {
            backendVar.set(_expectedBackend());
        }
    }

    function openFolder() {
        Quickshell.execDetached(["xdg-open", outputDir]);
        return "opened";
    }

    function openLast() {
        const file = lastFileVar.value || "";
        if (!file)
            return "empty";
        Quickshell.execDetached(["xdg-open", file]);
        return "opened";
    }

    function status() {
        return JSON.stringify({
            "state": state,
            "elapsed": elapsedVar.value || 0,
            "backend": backendVar.value || "",
            "canvas": canvasVar.value || "",
            "lastFile": lastFileVar.value || "",
            "gpus": gpusVar.value || "",
            "caps": capsVar.value || ""
        });
    }

    // ── Processes and timers ───────────────────────────────────────────────
    Process {
        id: recorder
        onStarted: root._handleStarted()
        onExited: (exitCode, exitStatus) => root._handleExit(exitCode, exitStatus)
        stdout: StdioCollector { onStreamFinished: root._stdoutText = text || "" }
        stderr: StdioCollector { onStreamFinished: root._stderrText = text || "" }
    }

    // A candidate that cannot capture dies within a second or two. Anything
    // still running after the probe window is a live recording.
    Timer {
        id: probeTimer
        interval: 2500
        repeat: false
        onTriggered: {
            if (root.state === "starting" && recorder.running) {
                stateVar.set("recording");
                elapsedVar.set(0);
                elapsedTimer.start();
                backendVar.set(root._expectedBackend());
                root._notifyInfo("Recording started", root._pendingFile);
            }
        }
    }

    Timer {
        id: elapsedTimer
        interval: 1000
        repeat: true
        onTriggered: elapsedVar.set((elapsedVar.value || 0) + 1)
    }

    Timer {
        id: stopTimer
        interval: 8000
        repeat: false
        onTriggered: {
            if (recorder.running) {
                root._signal("SIGTERM");
                killTimer.restart();
            }
        }
    }

    Timer {
        id: killTimer
        interval: 2000
        repeat: false
        onTriggered: {
            if (recorder.running)
                root._signal("SIGKILL");
        }
    }

    // ── IPC ────────────────────────────────────────────────────────────────
    IpcHandler {
        target: "dankRecorder"

        function start(): string { return root.begin(""); }
        function startFullscreen(): string { return root.begin("primary"); }
        function startRegion(): string { return root.begin("region"); }
        function startPortal(): string { return root.begin("portal"); }
        function stop(): string { return root.stop(); }
        function toggle(): string { return root.toggle(); }
        function pause(): string { return root.togglePause(); }
        function toggleAudio(): string { return root.toggleAudio(); }
        function confirm(): string { return root.confirmStart(); }
        function cancel(): string { return root.cancelArmed(); }
        function reselect(): string { return root.reselectRegion(); }
        function fullscreen(): string { return root.useFullScreen(); }
        function status(): string { return root.status(); }
        function openFolder(): string { return root.openFolder(); }
        function openLast(): string { return root.openLast(); }
    }

    // ── Confirmation bar ───────────────────────────────────────────────────
    RecorderConfirmOverlay {
        targetScreen: root._armedScreen
        shown: root.armed
        canvasLabel: canvasVar.value || ""
        targetLabel: root._armedIsRegion ? I18n.trFor("dankRecorder", "Selected region") : I18n.trFor("dankRecorder", "Live desktop")
        isRegion: root._armedIsRegion
        audioText: root.audioText
        audioIcon: root.audioIcon
        audioOn: root.audioOn
        savedX: root.overlayX
        savedY: root.overlayY
        onStartRequested: root.confirmStart()
        onRegionRequested: root.reselectRegion()
        onFullRequested: root.useFullScreen()
        onAudioToggled: root.toggleAudio()
        onCancelRequested: root.cancelArmed()
        onPositionChosen: (x, y) => {
            // Remember where the user put the bar.
            if (!pluginService)
                return;
            pluginService.savePluginData("dankRecorder", "overlayX", Math.round(x));
            pluginService.savePluginData("dankRecorder", "overlayY", Math.round(y));
        }
    }

    Component.onCompleted: {
        detectGpus();
        detectCapabilities();
        stateVar.set("idle");
        elapsedVar.set(0);
        canvasVar.set("");
    }

    Component.onDestruction: {
        // Do not leave an orphan recorder behind on reload or disable.
        if (recorder.running && _pid > 0)
            _signal("SIGINT");
    }
}
