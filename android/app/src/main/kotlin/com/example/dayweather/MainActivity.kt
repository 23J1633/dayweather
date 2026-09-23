package com.example.dayweather

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.arashivision.inskmp.insble.data.BleDeviceCore
import com.arashivision.sdk.camera.InstaCameraSDK
import com.arashivision.sdk.camera.api.CameraDevice
import com.arashivision.sdk.camera.api.param.listener.BleWakeUpListener
import com.arashivision.sdk.camera.core.model.authorization.AuthorizationResult
import com.arashivision.sdk.camera.core.model.authorization.AuthorizationOperationType
import com.arashivision.sdk.camera.api.param.listener.AuthorizationListener
import com.arashivision.sdk.camera.api.param.listener.CaptureStatusListener
import com.arashivision.sdk.camera.api.param.listener.DisconnectListener
import com.arashivision.sdk.camera.core.callback.BleScanCallback
import com.arashivision.sdk.camera.core.model.CameraType
import com.arashivision.sdk.camera.core.model.ConnectType
import com.arashivision.sdk.camera.core.model.capture.CameraCaptureStatus
import com.arashivision.sdk.camera.core.model.FunctionMode
import com.arashivision.sdk.camera.core.model.option.SensorMode
import com.arashivision.sdk.camera.core.model.option.WiFiData
import com.arashivision.sdk.camera.api.preview.CameraStreamListener
import com.arashivision.sdk.camera.api.preview.PreviewStreamFrame
import com.arashivision.sdk.camera.api.preview.PreviewStreamParamsUpdate
import com.arashivision.sdk.common.exception.InstaException
import com.arashivision.sdk.media.InstaMediaSDK
import com.arashivision.sdk.media.api.listener.PlayerViewListener
import com.arashivision.sdk.media.api.params.PreviewParams
import com.arashivision.sdk.media.player.preview.InstaCapturePlayerView
import com.arashivision.sdk.media.api.work.WorkManager
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.coroutines.resume

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dayweather/native"
        private const val EVENTS_CHANNEL = "dayweather/native_events"
        private const val AI_EVENTS_CHANNEL = "dayweather/ai_events"
        /** Clips shorter than this are treated as accidental recordings. */
        private const val MIN_ANALYZABLE_MS = 5_000L
        private const val PREVIEW_VIEW = "dayweather/go-preview"
        private const val PERMISSION_REQUEST = 7001
    }

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val scannedDevices = linkedMapOf<String, BleDeviceCore>()
    private val connectivityManager by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private val wifiManager by lazy {
        getSystemService(Context.WIFI_SERVICE) as WifiManager
    }

    private var currentCamera: CameraDevice? = null
    private var scanCamera: CameraDevice? = null
    private var previewPlayer: InstaCapturePlayerView? = null
    private var previewStarted = false
    private var wifiNetwork: Network? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private var connectionJob: Job? = null
    private var eventSink: EventChannel.EventSink? = null
    private var aiEventSink: EventChannel.EventSink? = null
    private var currentDeviceId: String? = null
    private var internetTaskCount = 0
    @Volatile
    private var recordingActive = false
    @Volatile
    private var recordingElapsedMs = 0L
    private var lastReportedTick = -1L
    private var currentDeviceName: String? = null
    private var currentDeviceAddress: String? = null
    private var suppressDisconnectEvent = false
    @Volatile
    private var latestVideoTimestamp: Long? = null
    private var previewFrameSampling = false
    private val previewFrameHandler = Handler(Looper.getMainLooper())
    private val previewFrameSampler = object : Runnable {
        override fun run() {
            capturePreviewFrame()
            if (previewFrameSampling) {
                previewFrameHandler.postDelayed(this, 20_000L)
            }
        }
    }
    private val audioFrameLock = Any()
    private val pendingAudioBuffer = ByteArrayOutputStream(16 * 1024)
    private var pendingAudioTimestamp: Long? = null
    private var audioFrameCount = 0L
    private var audioByteCount = 0L

    /**
     * Huawei tablets hide application logcat output, so connection stages are also
     * appended to a file inside the app's external files dir for adb retrieval.
     */
    private fun diagLog(message: String) {
        android.util.Log.d("DayWeather", message)
        runCatching {
            val file = File(getExternalFilesDir(null), "diag.txt")
            file.appendText("${System.currentTimeMillis()} $message\n")
        }
    }

    /** Tracks recording state so the UI can drive 3-minute window summaries. */
    private val captureStatusListener = object : CaptureStatusListener {
        override fun onCaptureStarting(functionMode: FunctionMode) {
            emitNativeEvent("recording_starting")
        }

        override fun onCaptureWorking(functionMode: FunctionMode) {
            recordingActive = true
            emitNativeEvent("recording_started")
        }

        override fun onCaptureStopping(functionMode: FunctionMode) {
            emitNativeEvent("recording_stopping")
        }

        override fun onCaptureFinish(functionMode: FunctionMode, uris: List<String>) {
            recordingActive = false
            emitNativeEvent("recording_finished", extra = mapOf("paths" to uris))
            restoreLivePreviewAfterCapture()
        }

        override fun onCaptureError(functionMode: FunctionMode, throwable: Throwable) {
            recordingActive = false
            emitNativeEvent("recording_error", throwable.message)
            restoreLivePreviewAfterCapture()
        }

        override fun onCaptureTimeChanged(functionMode: FunctionMode, elapsedMs: Long) {
            recordingElapsedMs = elapsedMs
            // Surface a tick once per 10s so the window timer stays in sync with the
            // camera clock without flooding the event channel.
            if (elapsedMs / 10_000L != lastReportedTick) {
                lastReportedTick = elapsedMs / 10_000L
                emitNativeEvent("recording_tick", extra = mapOf("elapsedMs" to elapsedMs))
            }
        }

        override fun onCaptureCountChanged(functionMode: FunctionMode, count: Int) = Unit

        override fun onCaptureSubStatusChanged(
            functionMode: FunctionMode,
            subStatus: CameraCaptureStatus.SubStatus,
        ) = Unit
    }
    private val disconnectListener = object : DisconnectListener {
        override fun onDisconnect(throwable: Throwable?) {
            if (suppressDisconnectEvent) {
                suppressDisconnectEvent = false
                return
            }
            emitNativeEvent("disconnected", throwable?.message)
            mainScope.launch { releaseCamera(cancelConnectionJob = false) }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestCameraPermissions()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initInstaSdk()
        flutterEngine.platformViewsController.registry.registerViewFactory(
            PREVIEW_VIEW,
            GoPreviewFactory(this),
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethodCall)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                },
            )
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AI_EVENTS_CHANNEL)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        aiEventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        aiEventSink = null
                    }
                },
            )
    }

    override fun onDestroy() {
        stopPreview()
        releaseCamera()
        mainScope.cancel()
        super.onDestroy()
    }

    private fun initInstaSdk() {
        runCatching {
            InstaCameraSDK.init(application) {
                cacheDir = externalCacheDir?.absolutePath
            }
            InstaMediaSDK.init(application)
        }
    }

    private fun requestCameraPermissions() {
        val permissions = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                add(Manifest.permission.ACCESS_FINE_LOCATION)
                add(Manifest.permission.ACCESS_COARSE_LOCATION)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                add(Manifest.permission.READ_MEDIA_VIDEO)
                add(Manifest.permission.READ_MEDIA_AUDIO)
                add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (permissions.isNotEmpty()) requestPermissions(permissions.toTypedArray(), PERMISSION_REQUEST)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scanGoUltra",
            "wakeUpCamera",
            "connectProbe",
            "requestBleAuthorization",
            "dumpBleDeviceFields",
            "connectGoUltra",
            -> result.error(
                "CAMERA_BLE_DISABLED",
                "GO Ultra must be connected over Wi-Fi; Bluetooth is reserved for Mic Pro",
                null,
            )
            "connectCurrentWifiCamera" -> connectCurrentWifiCamera(result)
            "disconnectCamera" -> {
                releaseCamera()
                result.success(null)
            }
            "inspectMedia" -> inspectMedia(call, result)
            "extractAudioChunk" -> extractAudioChunk(call, result)
            "extractVideoFrames" -> extractVideoFrames(call, result)
            "exportVideoClip" -> exportVideoClip(call, result)
            "syncLatestMedia" -> syncLatestMedia(result)
            "listCameraVideos" -> listCameraVideos(result)
            "startRecording" -> startRecording(result)
            "stopRecording" -> stopRecording(result)
            "recordingAudioProbe" -> {
                result.success(mapOf("audioFrames" to audioFrameCount, "audioBytes" to audioByteCount))
            }
            "syncCameraVideo" -> syncCameraVideo(call, result)
            "shareWallpaper" -> shareWallpaper(call, result)
            "pushMicProWallpaper" -> pushMicProWallpaper(call, result)
            "prepareMicProPayloads" -> prepareMicProPayloads(call, result)
            "scanMicPro" -> scanMicPro(result)
            "connectMicPro" -> connectMicPro(call, result)
            "probeMicPro" -> probeMicPro(call, result)
            "useInternetNetwork" -> {
                bindInternetNetwork()
                result.success(null)
            }
            "beginInternetTask" -> {
                result.success(beginInternetTask())
            }
            "endInternetTask" -> {
                endInternetTask()
                result.success(null)
            }
            "useCameraNetwork" -> {
                bindCameraNetwork()
                result.success(null)
            }
            "startPreview" -> {
                startPreview()
                result.success(null)
            }
            "aiHttpPost" -> aiHttpPost(call, result)
            "aiWsOpen" -> aiWsOpen(call, result)
            "aiWsSend" -> aiWsSend(call, result)
            "aiWsClose" -> aiWsClose(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Wakes a sleeping GO Ultra before connecting. The SDK expects the trailing 6
     * characters of the serial, which is exactly what the BLE name exposes, so the
     * common path does not require pressing the shutter on the Action Pod.
     */
    private fun wakeUpCamera(call: MethodCall, result: MethodChannel.Result) {
        val deviceName = call.argument<String>("deviceName")
        val cameraTypeName = call.argument<String>("cameraType") ?: "GO_ULTRA"
        if (deviceName.isNullOrBlank()) {
            result.error("WAKE_NAME_EMPTY", "A device name is required to wake the camera", null)
            return
        }
        val cameraType = runCatching { CameraType.valueOf(cameraTypeName) }
            .getOrDefault(CameraType.GO_ULTRA)
        val ble = CameraDevice.get(ConnectType.BLE)
        val finished = java.util.concurrent.atomic.AtomicBoolean(false)
        fun finish(ok: Boolean, detail: String?) {
            if (!finished.compareAndSet(false, true)) return
            runOnUiThread {
                if (ok) {
                    emitNativeEvent("wake_up_success")
                    result.success(null)
                } else {
                    emitNativeEvent("wake_up_failed", detail)
                    result.error("WAKE_UP_FAILED", detail ?: "Camera wake up failed", null)
                }
            }
        }
        diagLog("wakeUp: invoke type=$cameraType name=$deviceName")
        ble.bleWakeUp(
            cameraType,
            deviceName,
            object : BleWakeUpListener {
                override fun onWakeUpSuccess() {
                    diagLog("wakeUp: success")
                    finish(true, null)
                }

                override fun onWakeUpError(errCode: Int) {
                    diagLog("wakeUp: error code=$errCode")
                    finish(false, "wake up error code=$errCode")
                }
            },
        )
        mainScope.launch {
            kotlinx.coroutines.delay(15_000L)
            if (finished.compareAndSet(false, true)) {
                runCatching { ble.release() }
                runOnUiThread {
                    diagLog("wakeUp: timeout after 15s"); emitNativeEvent("wake_up_failed", "timeout")
                    result.error("WAKE_UP_TIMEOUT", "Camera did not respond to wake up", null)
                }
            }
        }
    }

    /** Introspects the scanned device so the wake-up API can receive a serial. */
    private fun dumpBleDeviceFields(result: MethodChannel.Result) {
        val device = scannedDevices.values.firstOrNull()
        if (device == null) {
            result.error("NO_DEVICE", "Scan first so a device is available", null)
            return
        }
        val info = linkedMapOf<String, Any?>()
        info["className"] = device.javaClass.name
        for (method in device.javaClass.methods) {
            if (method.parameterCount != 0) continue
            val name = method.name
            if (name.startsWith("get") || name.startsWith("is")) {
                if (name == "getClass") continue
                val value = runCatching { method.invoke(device) }.getOrNull()
                info[name] = value?.toString()
            }
        }
        result.success(info)
    }

    /**
     * GO Ultra and GO 3S require an explicit BLE authorization: the camera shows a
     * prompt on the Action Pod and the app must listen for the result. Without this
     * step the handshake fails with "wake up authorization failed".
     */
    private fun requestBleAuthorization(result: MethodChannel.Result) {
        // Before the Wi-Fi hand-off the BLE scan camera is the only live SDK handle.
        // Using currentCamera here made the pre-connect authorization request a
        // guaranteed no-op because currentCamera is assigned only after Wi-Fi works.
        // A failed BLE handshake is followed by releaseCamera(), so both live
        // references may be cleared before the Dart recovery path asks for auth.
        // Reuse the SDK BLE singleton in that case; checkAuthorization() is the
        // official SDK entry point that can surface the Action Pod prompt.
        val camera = currentCamera ?: scanCamera ?: CameraDevice.get(ConnectType.BLE).also {
            scanCamera = it
        }
        mainScope.launch {
            runCatching {
                camera.registerAuthorizationListener(authorizationListener)
                // The result also arrives through the listener; this call kicks off
                // the camera-side prompt on the Action Pod.
                camera.checkAuthorization().getOrThrow()
            }.onSuccess { status ->
                emitNativeEvent("authorization_requested", detail = status.toString())
                result.success(status.toString())
            }.onFailure { error ->
                emitNativeEvent("authorization_failed", error.message)
                result.error("AUTHORIZATION_FAILED", error.message, null)
            }
        }
    }

    /** Surfaces the camera-side authorization outcome to Flutter. */
    private val authorizationListener = object : AuthorizationListener {
        override fun onAuthorizationResult(
            operationType: AuthorizationOperationType,
            authorizationResult: AuthorizationResult,
        ) {
            emitNativeEvent(
                "authorization_result",
                detail = "$operationType/$authorizationResult",
            )
        }
    }

    /**
     * Runs the BLE handshake step by step and reports which stage fails, so the
     * wake-up requirement can be diagnosed without relying on device logcat.
     */
    private fun connectProbe(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val device = scannedDevices[id]
        if (device == null) {
            result.error("NO_DEVICE", "Scan first, then probe the same id", null)
            return
        }
        mainScope.launch {
            val steps = linkedMapOf<String, Any?>()
            steps["deviceName"] = device.name.toString()
            steps["address"] = device.address
            val ble = CameraDevice.get(ConnectType.BLE)
            val outcomes = mutableListOf<String>()
            runCatching { ble.connect(device, false).getOrThrow() }
                .onSuccess { outcomes += "ble=OK" }
                .onFailure { outcomes += "ble=FAIL(${it.message})" }
            runCatching {
                val wifi = ble.system.fetchWifiData().getOrNull()
                outcomes += "wifiMode=${wifi?.mode}"
                if (wifi?.mode == WiFiData.Mode.AP) {
                    val creds = ble.system.getWifiData().getOrNull()
                    outcomes += "ssid=${creds?.ssid}"
                }
            }.onFailure { outcomes += "wifiData=FAIL(${it.message})" }
            runCatching { ble.release() }
            steps["outcomes"] = outcomes
            runOnUiThread { result.success(steps) }
        }
    }

    private fun scanGoUltra(result: MethodChannel.Result) {
        emitNativeEvent("scan_started")
        scannedDevices.clear()
        scanCamera?.stopScan()
        val camera = CameraDevice.get(ConnectType.BLE)
        scanCamera = camera
        var finished = false
        camera.scan(
            8_000L,
            object : BleScanCallback {
                override fun onStarted() = Unit

                override fun onScanning(bleDevice: BleDeviceCore) {
                    val name = bleDevice.name.toString()
                    if (name.contains("GO", ignoreCase = true)) {
                        // BLE controllers rotate random addresses, so the same camera can
                        // be reported repeatedly. Collapse entries that share a name and
                        // drop the stale address mapping to keep the list trustworthy.
                        val duplicateAddresses = scannedDevices
                            .filterValues { it.name.toString() == name && it.address != bleDevice.address }
                            .keys
                        duplicateAddresses.forEach { scannedDevices.remove(it) }
                        scannedDevices[bleDevice.address] = bleDevice
                    }
                }

                override fun onFinished(bleDeviceList: List<BleDeviceCore>) {
                    if (finished) return
                    finished = true
                    bleDeviceList
                        .filter { it.name.toString().contains("GO", ignoreCase = true) }
                        .forEach { device ->
                            val name = device.name.toString()
                            val duplicateAddresses = scannedDevices
                                .filterValues { it.name.toString() == name && it.address != device.address }
                                .keys
                            duplicateAddresses.forEach { scannedDevices.remove(it) }
                            scannedDevices[device.address] = device
                        }
                    emitNativeEvent(
                        "scan_finished",
                        extra = mapOf("count" to scannedDevices.size),
                    )
                    result.success(scannedDevices.values.map(::deviceMap))
                }

                override fun onError(throwable: Throwable) {
                    if (finished) return
                    finished = true
                    emitNativeEvent("scan_failed", throwable.message)
                    result.error("BLE_SCAN_FAILED", throwable.message, null)
                }
            },
        )
    }

    private fun connectGoUltra(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val bleDevice = scannedDevices[id]
        if (bleDevice == null) {
            result.error("DEVICE_NOT_FOUND", "The selected GO Ultra is no longer in the scan list", null)
            return
        }
        connectionJob?.cancel()
        releaseCamera(cancelConnectionJob = false)
        currentDeviceId = id
        currentDeviceName = bleDevice.name.toString()
        currentDeviceAddress = bleDevice.address
        connectionJob = mainScope.launch {
            try {
                connectBleThenWifi(bleDevice)
                emitNativeEvent(
                    "connected",
                    extra = mapOf(
                        "deviceId" to (currentDeviceId ?: id),
                        "deviceName" to (currentDeviceName ?: bleDevice.name.toString()),
                    ),
                )
                result.success(deviceMapForCamera())
            } catch (error: CancellationException) {
                runCatching { releaseCamera(cancelConnectionJob = false) }
                result.error("CONNECT_CANCELLED", "GO Ultra connection was cancelled", null)
            } catch (error: Throwable) {
                val detail = connectionErrorMessage(error)
                emitNativeEvent("connection_failed", detail)
                val needsBleAuthorization = detail.contains("authorization", ignoreCase = true)
                if (needsBleAuthorization) {
                    // Keep the failed BLE session alive long enough for the
                    // official checkAuthorization() recovery call to reach the
                    // Action Pod. The next connect attempt releases it normally.
                    stopPreview()
                    flushPendingAudioFrame()
                    currentCamera?.let { camera ->
                        suppressDisconnectEvent = true
                        runCatching { camera.unregisterDisconnectListener(disconnectListener) }
                        runCatching { camera.release() }
                    }
                    currentCamera = null
                    connectivityManager.bindProcessToNetwork(null)
                    unregisterWifiCallback()
                    wifiNetwork = null
                    diagLog("connect: retaining BLE handle for authorization recovery")
                } else {
                    runCatching { releaseCamera(cancelConnectionJob = false) }
                }
                result.error("CONNECT_FAILED", detail, null)
            } finally {
                connectionJob = null
            }
        }
    }

    /**
     * Connects the SDK directly to the Wi-Fi network the tablet is already using.
     *
     * This is the primary camera path for DayWeather: the tablet joins the GO
     * Ultra AP through Android system Wi-Fi, then the SDK is attached to that
     * Network handle. BLE discovery is intentionally not involved here.
     */
    private fun connectCurrentWifiCamera(result: MethodChannel.Result) {
        connectionJob?.cancel()
        releaseCamera(cancelConnectionJob = false)
        val network = currentWifiNetwork()
        if (network == null) {
            result.error(
                "WIFI_NOT_CONNECTED",
                "Join the GO Ultra camera Wi-Fi in Android settings first",
                null,
            )
            return
        }
        val ssid = currentWifiSsid()
        currentDeviceId = "wifi:${ssid.ifBlank { network.networkHandle.toString() }}"
        currentDeviceName = if (ssid.isBlank()) "GO Ultra Wi-Fi" else "GO Ultra $ssid"
        currentDeviceAddress = null
        connectionJob = mainScope.launch {
            try {
                wifiNetwork = network
                if (!connectivityManager.bindProcessToNetwork(network)) {
                    error("Android could not bind the current Wi-Fi network")
                }
                emitNativeEvent("connecting_wifi", deviceName = currentDeviceName)
                diagLog("direct wifi.connect start ssid=$ssid handle=${network.networkHandle}")
                val wifiCamera = CameraDevice.get(ConnectType.WIFI)
                wifiCamera.connect(network.networkHandle)
                    .onSuccess { diagLog("direct wifi.connect OK") }
                    .onFailure { diagLog("direct wifi.connect FAIL: ${it.message}") }
                    .getOrThrow()
                currentCamera = wifiCamera
                wifiCamera.registerDisconnectListener(disconnectListener)
                runCatching {
                    wifiCamera.capture.registerCaptureStatusListener(captureStatusListener)
                }
                emitNativeEvent("camera_ready", deviceName = currentDeviceName)
                startPreview()
                result.success(deviceMapForCamera())
            } catch (error: CancellationException) {
                runCatching { releaseCamera(cancelConnectionJob = false) }
                result.error("CONNECT_CANCELLED", "GO Ultra Wi-Fi connection was cancelled", null)
            } catch (error: Throwable) {
                val detail = error.message?.trim().orEmpty()
                emitNativeEvent("connection_failed", detail)
                diagLog("direct wifi.connect error: $detail")
                runCatching { releaseCamera(cancelConnectionJob = false) }
                val userMessage = if (detail.contains("camera connect failed", ignoreCase = true)) {
                    "当前 Wi-Fi 不是可访问的 GO Ultra 相机网络，请先在系统 Wi-Fi 设置中连接相机热点（SDK：$detail）"
                } else {
                    detail.ifBlank { "当前 Wi-Fi 无法访问 GO Ultra 相机" }
                }
                result.error(
                    "WIFI_CONNECT_FAILED",
                    userMessage,
                    null,
                )
            } finally {
                connectionJob = null
            }
        }
    }

    private fun currentWifiNetwork(): Network? {
        val active = connectivityManager.activeNetwork
        if (active != null && isWifiNetwork(active)) return active
        return connectivityManager.allNetworks.firstOrNull(::isWifiNetwork)
    }

    private fun isWifiNetwork(network: Network): Boolean {
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    private fun currentWifiSsid(): String {
        return wifiManager.connectionInfo?.ssid
            ?.trim()
            ?.removePrefix("\"")
            ?.removeSuffix("\"")
            ?.takeUnless { it.isBlank() || it == "<unknown ssid>" }
            .orEmpty()
    }

    private fun connectionErrorMessage(error: Throwable): String {
        val raw = error.message?.trim().orEmpty()
        val normalized = raw.lowercase()
        return if (
            normalized.contains("wake up authorization") ||
                normalized.contains("authorization failed")
        ) {
            "GO Ultra 尚未完成相机端授权，请在 Action Pod 上点击确认或按快门授权后重试（SDK：$raw）"
        } else {
            raw.ifBlank { "Unable to connect to GO Ultra" }
        }
    }

    private suspend fun connectBleThenWifi(bleDevice: BleDeviceCore) {
        val bleCamera = CameraDevice.get(ConnectType.BLE)
        scanCamera = bleCamera
        emitNativeEvent("connecting_ble", deviceName = bleDevice.name.toString())
        diagLog("ble.connect start name=${bleDevice.name} addr=${bleDevice.address}")
        // Use BLE only as a short control bootstrap. The production transport
        // remains the camera Wi-Fi Network handed to ConnectType.WIFI below.
        bleCamera.connect(bleDevice, true)
            .onSuccess { diagLog("ble.connect OK") }
            .onFailure { diagLog("ble.connect FAIL: ${it.message}") }
            .getOrThrow()
        emitNativeEvent("ble_connected", deviceName = bleDevice.name.toString())
        diagLog("ap mode: enter")
        val wifiData = ensureCameraApMode(bleCamera)
            ?: error("GO Ultra did not provide Wi-Fi credentials")
        emitNativeEvent(
            "requesting_wifi",
            deviceName = bleDevice.name.toString(),
            extra = mapOf("ssid" to wifiData.ssid),
        )
        val network = requestCameraWifi(wifiData.ssid, wifiData.pwd)
            ?: error("Android did not grant a temporary camera Wi-Fi network")
        wifiNetwork = network
        if (!connectivityManager.bindProcessToNetwork(network)) {
            error("Android could not bind the camera Wi-Fi network")
        }
        emitNativeEvent("wifi_available", deviceName = bleDevice.name.toString())
        runCatching { bleCamera.release() }
        val wifiCamera = CameraDevice.get(ConnectType.WIFI)
        emitNativeEvent("connecting_wifi", deviceName = bleDevice.name.toString())
        diagLog("wifi.connect start handle=${network.networkHandle}")
        wifiCamera.connect(network.networkHandle)
            .onSuccess { diagLog("wifi.connect OK") }
            .onFailure { diagLog("wifi.connect FAIL: ${it.message}") }
            .getOrThrow()
        currentCamera = wifiCamera
        wifiCamera.registerDisconnectListener(disconnectListener)
        // Register right after connecting so recordings started from the Action Pod
        // shutter are observed as well, mirroring the official demo lifecycle.
        runCatching { wifiCamera.capture.registerCaptureStatusListener(captureStatusListener) }
        emitNativeEvent("camera_ready", deviceName = bleDevice.name.toString())
        startPreview()
    }

    private suspend fun ensureCameraApMode(camera: CameraDevice): com.arashivision.sdk.camera.core.model.option.WiFiData? {
        val current = camera.system.fetchWifiData().getOrNull()
        if (current?.mode == WiFiData.Mode.AP) return camera.system.getWifiData().getOrNull()
        emitNativeEvent("switching_ap")
        camera.system.setWifiMode(WiFiData.Mode.AP, "").getOrThrow()
        repeat(12) {
            val data = camera.system.fetchWifiData().getOrNull()
            if (data?.mode == WiFiData.Mode.AP) return camera.system.getWifiData().getOrNull()
            delay(500)
        }
        error("GO Ultra did not enter AP Wi-Fi mode")
    }

    private suspend fun requestCameraWifi(ssid: String, password: String): Network? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        if (!wifiManager.isWifiEnabled) return null
        unregisterWifiCallback()
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .setNetworkSpecifier(specifier)
            .build()
        return suspendCancellableCoroutine { continuation ->
            var resumed = false
            fun finish(network: Network?) {
                if (resumed) return
                resumed = true
                if (continuation.isActive) continuation.resume(network)
            }
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    wifiCallback = this
                    finish(network)
                }

                override fun onUnavailable() = finish(null)

                override fun onLost(network: Network) {
                    if (network == wifiNetwork) finish(null)
                }
            }
            wifiCallback = callback
            connectivityManager.requestNetwork(request, callback)
            continuation.invokeOnCancellation {
                runCatching { connectivityManager.unregisterNetworkCallback(callback) }
            }
        }
    }

    private fun releaseCamera(cancelConnectionJob: Boolean = true) {
        if (cancelConnectionJob) {
            connectionJob?.cancel()
            connectionJob = null
        }
        stopPreview()
        flushPendingAudioFrame()
        runCatching { scanCamera?.stopScan() }
        currentCamera?.let { camera ->
            suppressDisconnectEvent = true
            runCatching { camera.unregisterDisconnectListener(disconnectListener) }
        }
        aiWebSocket?.cancel()
        aiWebSocket = null
        synchronized(aiClients) { aiClients.clear() }
        runCatching { currentCamera?.release() }
        runCatching { scanCamera?.release() }
        currentCamera = null
        scanCamera = null
        currentDeviceId = null
        currentDeviceName = null
        currentDeviceAddress = null
        suppressDisconnectEvent = false
        connectivityManager.bindProcessToNetwork(null)
        unregisterWifiCallback()
        wifiNetwork = null
    }

    private fun bindInternetNetwork() {
        if (connectivityManager.bindProcessToNetwork(null)) {
            emitNativeEvent("internet_ready")
        }
    }

    /**
     * Routes AI traffic over the mobile network while the process stays bound to the
     * camera Wi-Fi, so media transfer and cloud analysis can run at the same time.
     * Returns the network handle to later [endInternetTask], or -1 when only one
     * network is available and traffic should keep using the process default.
     */
    private fun beginInternetTask(): Long {
        val internetNetwork = activeInternetNetwork() ?: return -1L
        internetTaskCount += 1
        return internetNetwork.networkHandle
    }

    private fun endInternetTask() {
        if (internetTaskCount > 0) internetTaskCount -= 1
    }

    /**
     * Picks a validated non-camera network (mobile data or a regular Wi-Fi with
     * internet access). The camera network is explicitly skipped because it has no
     * upstream connectivity.
     */
    private fun activeInternetNetwork(): Network? {
        val cameraNetwork = wifiNetwork
        for (network in connectivityManager.allNetworks) {
            if (cameraNetwork != null && network.networkHandle == cameraNetwork.networkHandle) continue
            val caps = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) continue
            return network
        }
        return null
    }
    // region Cloud AI transport (mobile data while the process stays on camera Wi-Fi)

    private val aiHttpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(180, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
            .callTimeout(200, TimeUnit.SECONDS)
            .build()
    }

    private var aiWebSocket: WebSocket? = null

    private val aiClients = java.util.concurrent.ConcurrentHashMap<Long, OkHttpClient>()

    /** Builds an OkHttp client whose sockets bypass the camera-Wi-Fi process binding. */
    private fun aiClientFor(network: Network): OkHttpClient =
        aiClients.getOrPut(network.networkHandle) {
            aiHttpClient.newBuilder()
                .socketFactory(network.socketFactory)
                .dns(object : okhttp3.Dns {
                    override fun lookup(hostname: String): List<java.net.InetAddress> =
                        network.getAllByName(hostname).toList()
                })
                .build()
        }

    private fun aiClient(): OkHttpClient {
        val network = activeInternetNetwork() ?: return aiHttpClient
        return aiClientFor(network)
    }

    /**
     * Resolves the client used for cloud traffic. When the process is pinned to the
     * camera Wi-Fi and no mobile data is available, cloud calls cannot succeed, so a
     * dedicated error code lets the UI explain the missing connection.
     */
    private fun aiClientOrNull(): OkHttpClient? {
        val cameraBound = wifiNetwork != null
        val network = activeInternetNetwork()
        if (network == null && cameraBound) return null
        return if (network == null) aiHttpClient else aiClientFor(network)
    }

    private fun aiHttpPost(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val headers = call.argument<Map<String, String>>("headers").orEmpty()
        val body = call.argument<String>("body").orEmpty()
        if (url.isNullOrBlank()) {
            result.error("AI_URL_EMPTY", "AI request URL is empty", null)
            return
        }
        val client = aiClientOrNull()
        if (client == null) {
            result.error(
                "AI_NO_INTERNET",
                "Camera Wi-Fi has no internet access; enable mobile data to run cloud analysis",
                null,
            )
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder()
                    .url(url)
                    .post(body.toRequestBody("application/json".toMediaType()))
                    .apply { headers.forEach { (key, value) -> header(key, value) } }
                    .build()
                client.newCall(request).execute().use { response ->
                    mapOf(
                        "statusCode" to response.code,
                        "body" to response.body?.string().orEmpty(),
                    )
                }
            }.onSuccess { value -> runOnUiThread { result.success(value) } }
                .onFailure { error -> runOnUiThread { result.error("AI_HTTP_FAILED", error.message, null) } }
        }
    }

    private fun aiWsOpen(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val headers = call.argument<Map<String, String>>("headers").orEmpty()
        if (url.isNullOrBlank()) {
            result.error("AI_URL_EMPTY", "AI WebSocket URL is empty", null)
            return
        }
        val client = aiClientOrNull()
        if (client == null) {
            result.error(
                "AI_NO_INTERNET",
                "Camera Wi-Fi has no internet access; enable mobile data for realtime ASR",
                null,
            )
            return
        }
        aiWebSocket?.cancel()
        val request = Request.Builder()
            .url(url)
            .apply { headers.forEach { (key, value) -> header(key, value) } }
            .build()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                emitAiEvent("ai_ws_open")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                emitAiEvent("ai_ws_message", extra = mapOf("text" to text))
            }

            override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                emitAiEvent("ai_ws_binary", extra = mapOf("data" to bytes.toByteArray()))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                emitAiEvent("ai_ws_failed", t.message ?: "AI WebSocket failed")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                emitAiEvent("ai_ws_closed", extra = mapOf("code" to code, "reason" to reason))
            }
        }
        aiWebSocket = client.newWebSocket(request, listener)
        result.success(null)
    }

    private fun aiWsSend(call: MethodCall, result: MethodChannel.Result) {
        val socket = aiWebSocket
        if (socket == null) {
            result.error("AI_WS_NOT_OPEN", "AI WebSocket is not open", null)
            return
        }
        val text = call.argument<String>("text")
        val binary = call.argument<ByteArray>("data")
        val ok = when {
            binary != null -> socket.send(binary.toByteString())
            text != null -> socket.send(text)
            else -> false
        }
        result.success(ok)
    }

    private fun aiWsClose(result: MethodChannel.Result) {
        aiWebSocket?.close(1000, null)
        aiWebSocket = null
        result.success(null)
    }

    // endregion

    private fun bindCameraNetwork() {
        val network = wifiNetwork ?: return
        if (connectivityManager.bindProcessToNetwork(network)) {
            emitNativeEvent("camera_network_ready")
        }
    }

    private fun unregisterWifiCallback() {
        wifiCallback?.let { callback -> runCatching { connectivityManager.unregisterNetworkCallback(callback) } }
        wifiCallback = null
    }

    private fun deviceModel(name: String): String = when {
        name.contains("GO Ultra", ignoreCase = true) -> "GO Ultra"
        name.contains("GO 3S", ignoreCase = true) -> "GO 3S"
        name.contains("GO 3", ignoreCase = true) -> "GO 3"
        name.contains("GO 2", ignoreCase = true) -> "GO 2"
        name.contains("GO", ignoreCase = true) -> "GO"
        else -> "Unknown"
    }

    private fun deviceMap(bleDevice: BleDeviceCore): Map<String, Any?> {
        val name = bleDevice.name.toString()
        return mapOf(
        "id" to bleDevice.address,
        "name" to name,
        "model" to deviceModel(name),
        "connection" to "BLE / Wi‑Fi",
        "isConnected" to false,
        "address" to bleDevice.address,
        )
    }

    private fun deviceMapForCamera(): Map<String, Any?> {
        val name = currentDeviceName ?: "GO Ultra"
        return mapOf(
        "id" to (currentDeviceId ?: "go-ultra"),
        "name" to name,
        "model" to deviceModel(name),
        "connection" to "Wi‑Fi",
        "isConnected" to true,
        "battery" to null,
        "storage" to null,
        "address" to currentDeviceAddress,
        )
    }

    private fun emitNativeEvent(
        stage: String,
        detail: String? = null,
        deviceName: String? = null,
        extra: Map<String, Any?> = emptyMap(),
    ) {
        val payload = linkedMapOf<String, Any?>(
            "stage" to stage,
            "detail" to detail,
            "deviceId" to currentDeviceId,
            "deviceName" to (deviceName ?: currentDeviceName),
        )
        payload.putAll(extra)
        runOnUiThread { eventSink?.success(payload) }
    }

    private fun emitAiEvent(
        stage: String,
        detail: String? = null,
        extra: Map<String, Any?> = emptyMap(),
    ) {
        val payload = linkedMapOf<String, Any?>(
            "stage" to stage,
            "detail" to detail,
        )
        payload.putAll(extra)
        runOnUiThread { aiEventSink?.success(payload) }
    }

    private fun syncLatestMedia(result: MethodChannel.Result) {
        val camera = currentCamera
        if (camera == null) {
            result.error("CAMERA_NOT_CONNECTED", "Connect GO Ultra before syncing media", null)
            return
        }
        bindCameraNetwork()
        emitNativeEvent("sync_started")
        mainScope.launch(Dispatchers.IO) {
            runCatching {
                val works = WorkManager.getAllCameraWorks().getOrThrow()
                    .filter { it.isVideo() }
                    .sortedByDescending { it.getCreationTime() }
                // Accidental taps leave sub-second clips on the card; those carry no
                // audio track and would derail analysis, so prefer a clip long enough
                // to analyze and fall back only when nothing else exists.
                val latest = works.firstOrNull { it.getTotalDurationInMs() >= MIN_ANALYZABLE_MS }
                    ?: works.firstOrNull()
                    ?: error("GO Ultra has no video media to sync")
                // Reuse an already downloaded file. The auto-sync timer runs every
                // 20 seconds and re-downloading the same clip would saturate the
                // camera link and keep the GO Ultra busy.
                val cachedPath = findCachedDownload(latest)
                val downloadedPaths = if (cachedPath != null) {
                    listOf(cachedPath)
                } else {
                    latest.download { total, progress ->
                    emitNativeEvent(
                            "sync_progress",
                            extra = mapOf("total" to total, "progress" to progress),
                        )
                    }.getOrThrow()
                }
                val path = downloadedPaths.firstOrNull { it.isNotBlank() }
                    ?: error("GO Ultra returned no local video path")
                mapOf(
                    "path" to path,
                    "name" to File(path).name,
                    "durationMs" to latest.getTotalDurationInMs(),
                    "creationTimeMs" to latest.getCreationTime(),
                )
            }.onSuccess { value ->
                emitNativeEvent("sync_ready", extra = mapOf("path" to value["path"]))
                // Keep the process bound to the camera Wi-Fi: unbinding here would
                // drop the SDK connection. Cloud calls use the AI transport instead.
                withContext(Dispatchers.Main) { result.success(value) }
            }.onFailure { error ->
                emitNativeEvent("sync_failed", error.message)
                withContext(Dispatchers.Main) {
                    result.error("MEDIA_SYNC_FAILED", error.message, null)
                }
            }
        }
    }

    /**
     * Looks for a previously downloaded copy of the given camera work. Downloads are
     * keyed by a timestamped folder, so the newest matching file name wins.
     */
    /**
     * Records to the camera card using the official SDK mode transition.
     * VIDEO_LIVE is preview-only on GO Ultra and cannot accept startCapture().
     */
    private fun startRecording(result: MethodChannel.Result) {
        val camera = currentCamera
        if (camera == null) {
            result.error("CAMERA_NOT_CONNECTED", "Connect GO Ultra before recording", null)
            return
        }
        mainScope.launch {
            runCatching {
                // The official demo switches away from VIDEO_LIVE before capture.
                // Stop the stream first so the camera can accept the mode change.
                if (previewStarted) stopPreview()
                camera.capture.functionMode.setValue(FunctionMode.VIDEO_NORMAL).getOrThrow()
                camera.capture.syncAllParams()
                camera.capture.registerCaptureStatusListener(captureStatusListener)
                camera.capture.startCapture()
            }.onSuccess { result.success(null) }
                .onFailure { error ->
                    // A rejected mode switch or capture command must not leave the
                    // device without the live preview that the main screen expects.
                    startPreview()
                    emitNativeEvent("recording_error", error.message)
                    result.error("RECORD_START_FAILED", error.message, null)
                }
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val camera = currentCamera
        if (camera == null) {
            result.error("CAMERA_NOT_CONNECTED", "Connect GO Ultra before recording", null)
            return
        }
        mainScope.launch {
            runCatching { camera.capture.stopCapture() }
                .onSuccess { result.success(null) }
                .onFailure { error ->
                    emitNativeEvent("recording_error", error.message)
                    result.error("RECORD_STOP_FAILED", error.message, null)
                }
        }
    }

    private fun restoreLivePreviewAfterCapture() {
        mainScope.launch {
            // The capture-finish callback can arrive before the camera has fully
            // released its normal-recording state. Give the SDK a short settling
            // interval, then let startPreview apply VIDEO_LIVE in the official
            // lensType -> functionMode -> stream order.
            delay(250)
            if (currentCamera != null && !previewStarted) startPreview()
        }
    }

    /** Lists every video on the card so the user can pick which clip to analyze. */
    private fun listCameraVideos(result: MethodChannel.Result) {
        if (currentCamera == null) {
            result.error("CAMERA_NOT_CONNECTED", "Connect GO Ultra before listing media", null)
            return
        }
        bindCameraNetwork()
        mainScope.launch(Dispatchers.IO) {
            runCatching {
                WorkManager.getAllCameraWorks().getOrThrow()
                    .filter { it.isVideo() }
                    .sortedByDescending { it.getCreationTime() }
                    .map { work ->
                        mapOf(
                            "key" to mediaWorkKey(work),
                            "name" to (work.allUrls
                                .firstOrNull { it.endsWith(".mp4", ignoreCase = true) }
                                ?.let { File(it).name }
                                ?: "GO Ultra video"),
                            "durationMs" to work.getTotalDurationInMs(),
                            "sizeBytes" to work.getFileSize(),
                            "creationTimeMs" to work.getCreationTime(),
                        )
                    }
            }.onSuccess { value -> runOnUiThread { result.success(value) } }
                .onFailure { error ->
                    runOnUiThread { result.error("MEDIA_LIST_FAILED", error.message, null) }
                }
        }
    }

    /** Downloads one selected camera clip, reusing a complete cached copy when present. */
    private fun syncCameraVideo(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        if (currentCamera == null) {
            result.error("CAMERA_NOT_CONNECTED", "Connect GO Ultra before syncing media", null)
            return
        }
        if (key.isNullOrBlank()) {
            result.error("MEDIA_KEY_EMPTY", "A camera video key is required", null)
            return
        }
        bindCameraNetwork()
        emitNativeEvent("sync_started")
        mainScope.launch(Dispatchers.IO) {
            runCatching {
                val works = WorkManager.getAllCameraWorks().getOrThrow()
                    .filter { it.isVideo() }
                    .sortedByDescending { it.getCreationTime() }
                val target = works.firstOrNull { mediaWorkKey(it) == key }
                    ?: error("The selected GO Ultra video is no longer on the card")
                val cached = downloadedWorkPaths[key]?.takeIf { candidate ->
                    File(candidate).let { it.isFile && isCompleteMp4(it) }
                } ?: findCachedDownload(target)
                val paths = if (cached != null) {
                    android.util.Log.d("DayWeather", "selected media reused from cache: $cached")
                    listOf(cached)
                } else {
                    target.download { total, progress ->
                        emitNativeEvent(
                            "sync_progress",
                            extra = mapOf("total" to total, "progress" to progress),
                        )
                    }.getOrThrow()
                }
                val path = paths.firstOrNull { it.isNotBlank() }
                    ?: error("GO Ultra returned no local video path")
                downloadedWorkPaths[key] = path
                mapOf(
                    "path" to path,
                    "name" to File(path).name,
                    "durationMs" to target.getTotalDurationInMs(),
                    "creationTimeMs" to target.getCreationTime(),
                )
            }.onSuccess { value ->
                emitNativeEvent("sync_ready", extra = mapOf("path" to value["path"]))
                withContext(Dispatchers.Main) { result.success(value) }
            }.onFailure { error ->
                emitNativeEvent("sync_failed", error.message)
                withContext(Dispatchers.Main) {
                    result.error("MEDIA_SYNC_FAILED", error.message, null)
                }
            }
        }
    }
    /** Remembers which local file already holds a camera work, keyed per device clip. */
    private val downloadedWorkPaths = mutableMapOf<String, String>()

    private fun mediaWorkKey(work: com.arashivision.sdk.media.api.work.IWorkWrapper): String =
        "${work.getCreationTime()}_${work.getFileSize()}"
    private fun findCachedDownload(work: com.arashivision.sdk.media.api.work.IWorkWrapper): String? {
        val targetName = work.allUrls
            .firstOrNull { it.endsWith(".mp4", ignoreCase = true) }
            ?.let { File(it).name }
            ?: return null
        val downloadRoot = File(externalCacheDir, "insta/download")
        if (!downloadRoot.isDirectory) return null
        val candidates = downloadRoot.listFiles()
            ?.mapNotNull { folder ->
                File(folder, targetName).takeIf { it.isFile && isCompleteMp4(it) }
            }
            .orEmpty()
        return candidates.maxByOrNull { it.lastModified() }?.absolutePath
    }

    /**
     * An interrupted download leaves a truncated file behind: the leading `mdat`
     * box declares more bytes than the file actually has, and the trailing `moov`
     * box never arrives. Such a file has no readable audio track, so it must be
     * rejected and downloaded again.
     */
    private fun isCompleteMp4(file: File): Boolean {
        if (file.length() < 1024) return false
        return runCatching {
            val header = ByteArray(64)
            File(file.absolutePath).inputStream().use { stream ->
                if (stream.read(header) < 16) return false
            }
            var offset = 0
            while (offset + 8 <= header.size) {
                val size = ((header[offset].toLong() and 0xFF) shl 24) or
                    ((header[offset + 1].toLong() and 0xFF) shl 16) or
                    ((header[offset + 2].toLong() and 0xFF) shl 8) or
                    (header[offset + 3].toLong() and 0xFF)
                val type = String(header, offset + 4, 4, Charsets.US_ASCII)
                if (type == "mdat") {
                    // The box starts at `offset`; a complete file must also fit the
                    // trailing moov box that carries the track table.
                    return file.length() >= offset + size + 8
                }
                if (size < 8) return false
                offset += size.toInt()
            }
            false
        }.getOrDefault(false)
    }
    private fun inspectMedia(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("MEDIA_PATH_EMPTY", "Media path is empty", null)
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching {
                val retriever = MediaMetadataRetriever()
                retriever.setDataSource(path)
                val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                val recordedAtMs = parseMediaCreationTime(
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE),
                    path,
                )
                retriever.release()
                val extractor = MediaExtractor()
                extractor.setDataSource(path)
                var hasVideo = false
                var hasAudio = false
                var frameRate: Double? = null
                for (index in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(index)
                    val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                    if (mime.startsWith("video/")) {
                        hasVideo = true
                        if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) frameRate = format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
                    }
                    if (mime.startsWith("audio/")) hasAudio = true
                }
                extractor.release()
                mapOf("durationMs" to duration, "hasVideo" to hasVideo, "hasAudio" to hasAudio, "width" to width, "height" to height, "frameRate" to frameRate, "recordedAtMs" to recordedAtMs)
            }.onSuccess { value -> runOnUiThread { result.success(value) } }
                .onFailure { error -> runOnUiThread { result.error("MEDIA_INSPECT_FAILED", error.message, null) } }
        }
    }

    private fun parseMediaCreationTime(metadata: String?, path: String): Long? {
        val raw = metadata?.trim().orEmpty()
        if (raw.isNotEmpty()) {
            runCatching { Instant.parse(raw).toEpochMilli() }
                .getOrNull()
                ?.takeIf(::isPlausibleCreationTime)
                ?.let { return it }
            val formatters = listOf(
                DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss.SSS'Z'"),
                DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'"),
                DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSX"),
                DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss"),
            )
            for (formatter in formatters) {
                runCatching {
                    val local = LocalDateTime.parse(raw, formatter)
                    val zone = if (raw.endsWith("Z")) ZoneOffset.UTC else ZoneId.systemDefault()
                    val parsed = local.atZone(zone).toInstant().toEpochMilli()
                    if (isPlausibleCreationTime(parsed)) return parsed
                }
            }
        }
        val filename = File(path).name
        val match = Regex("(20\\d{2})(\\d{2})(\\d{2})[_-](\\d{2})(\\d{2})(\\d{2})").find(filename)
            ?: return null
        return runCatching {
            val groups = match.groupValues
            LocalDateTime.of(
                groups[1].toInt(),
                groups[2].toInt(),
                groups[3].toInt(),
                groups[4].toInt(),
                groups[5].toInt(),
                groups[6].toInt(),
            ).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                .takeIf(::isPlausibleCreationTime)
        }.getOrNull()
    }

    private fun isPlausibleCreationTime(value: Long): Boolean =
        value in 946684800000L..4102444800000L

    private fun extractAudioChunk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val startMs = call.argument<Int>("startMs") ?: 0
        val endMs = call.argument<Int>("endMs") ?: Int.MAX_VALUE
        if (path.isNullOrBlank()) {
            result.error("AUDIO_PATH_EMPTY", "Audio source path is empty", null)
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching { copyAudioTrack(path, startMs, endMs) }
                .onSuccess { file -> runOnUiThread { result.success(file?.absolutePath) } }
                .onFailure { error -> runOnUiThread { result.error("AUDIO_EXTRACT_FAILED", error.message, null) } }
        }
    }

    private fun extractVideoFrames(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val startMs = call.argument<Int>("startMs") ?: 0
        val endMs = call.argument<Int>("endMs") ?: Int.MAX_VALUE
        val count = call.argument<Int>("count") ?: 6
        if (path.isNullOrBlank()) {
            result.error("VIDEO_PATH_EMPTY", "Video source path is empty", null)
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching { sampleVideoFrames(path, startMs, endMs, count) }
                .onSuccess { frames ->
                    runOnUiThread { result.success(frames) }
                }
                .onFailure { error ->
                    runOnUiThread {
                        result.error("VIDEO_FRAME_EXTRACTION_FAILED", error.message, null)
                    }
                }
        }
    }

    private fun sampleVideoFrames(
        path: String,
        startMs: Int,
        endMs: Int,
        count: Int,
    ): List<Map<String, Any>> {
        val retriever = MediaMetadataRetriever()
        retriever.setDataSource(path)
        try {
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: 0L
            val safeStart = startMs.toLong().coerceAtLeast(0L).coerceAtMost(durationMs)
            val requestedEnd = if (endMs == Int.MAX_VALUE) durationMs else endMs.toLong()
            val safeEnd = requestedEnd.coerceAtLeast(safeStart + 1L).coerceAtMost(durationMs)
            val frameCount = count.coerceIn(1, 8)
            val span = (safeEnd - safeStart).coerceAtLeast(1L)
            val frames = mutableListOf<Map<String, Any>>()
            for (index in 0 until frameCount) {
                val timestampMs = safeStart + (span * (index * 2L + 1L) / (frameCount * 2L))
                val original = retriever.getFrameAtTime(
                    timestampMs * 1000L,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                ) ?: continue
                val scale = if (original.width > 640) 640f / original.width else 1f
                val bitmap = if (scale < 1f) {
                    Bitmap.createScaledBitmap(
                        original,
                        640,
                        (original.height * scale).toInt().coerceAtLeast(1),
                        true,
                    ).also { original.recycle() }
                } else {
                    original
                }
                val output = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 68, output)
                bitmap.recycle()
                val bytes = output.toByteArray()
                if (bytes.isNotEmpty()) {
                    frames += mapOf(
                        "timestampMs" to timestampMs,
                        "data" to bytes,
                    )
                }
            }
            return frames
        } finally {
            retriever.release()
        }
    }

    private fun copyAudioTrack(path: String, startMs: Int, endMs: Int): File? {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var audioIndex = -1
        var audioFormat: MediaFormat? = null
        for (index in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(index)
            if (format.getString(MediaFormat.KEY_MIME).orEmpty().startsWith("audio/")) {
                audioIndex = index
                audioFormat = format
                break
            }
        }
        if (audioIndex < 0 || audioFormat == null) {
            extractor.release()
            return null
        }
        extractor.selectTrack(audioIndex)
        val output = File(cacheDir, "dayweather_audio_${SystemClock.uptimeMillis()}.m4a")
        val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val outputTrack = muxer.addTrack(audioFormat)
        muxer.start()
        val startUs = startMs.toLong() * 1000L
        val endUs = endMs.toLong() * 1000L
        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        val maxInput = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 1024 * 1024
        val buffer = ByteBuffer.allocateDirect(maxInput.coerceIn(64 * 1024, 4 * 1024 * 1024))
        val info = MediaCodecBufferInfoCompat()
        while (true) {
            buffer.clear()
            val sampleTime = extractor.sampleTime
            if (sampleTime < 0 || sampleTime > endUs) break
            val sampleSize = extractor.readSampleData(buffer, 0)
            if (sampleSize <= 0) break
            info.set(0, sampleSize, (sampleTime - startUs).coerceAtLeast(0L), extractor.sampleFlags)
            muxer.writeSampleData(outputTrack, buffer, info.bufferInfo)
            extractor.advance()
        }
        runCatching { muxer.stop() }
        muxer.release()
        extractor.release()
        return output.takeIf { it.exists() && it.length() > 0 }
    }

    /**
     * Cuts a real sub-clip out of the source video and muxes it into a standalone
     * MP4. Both video and audio tracks are trimmed, so a highlight becomes an actual
     * edited clip rather than a pointer into the full recording.
     */
    private fun exportVideoClip(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val startMs = call.argument<Int>("startMs") ?: 0
        val endMs = call.argument<Int>("endMs") ?: 0
        val fileName = call.argument<String>("fileName")
        if (path.isNullOrBlank()) {
            result.error("CLIP_PATH_EMPTY", "Clip source path is empty", null)
            return
        }
        if (endMs <= startMs) {
            result.error("CLIP_RANGE_INVALID", "Clip end must be after its start", null)
            return
        }
        mainScope.launch(Dispatchers.IO) {
            diagLog("clip: export start $startMs..$endMs file=$fileName")
            runCatching { cutVideoClip(path, startMs, endMs, fileName) }
                .onSuccess { file ->
                    diagLog("clip: export done -> ${file?.absolutePath} size=${file?.length()}")
                    runOnUiThread { result.success(file?.absolutePath) }
                }
                .onFailure { error ->
                    diagLog("clip: export FAILED ${error.message}")
                    runOnUiThread { result.error("CLIP_EXPORT_FAILED", error.message, null) }
                }
        }
    }

    /** Writes the trimmed tracks into the cache directory and returns the new file. */
    private fun cutVideoClip(
        path: String,
        startMs: Int,
        endMs: Int,
        fileName: String?,
    ): File? {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        val safeName = (fileName ?: "dayweather_clip_${SystemClock.uptimeMillis()}")
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .let { if (it.endsWith(".mp4", true)) it else "$it.mp4" }
        val output = File(cacheDir, safeName)
        // Re-analysis may request the same logical clip again; never reuse stale
        // bytes from an earlier source or an earlier analysis attempt.
        if (output.exists()) output.delete()
        val muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var maxInputSize = 256 * 1024
        val trackPairs = mutableListOf<Pair<Int, Int>>()
        try {
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                if (!mime.startsWith("video/") && !mime.startsWith("audio/")) continue
                val outTrack = muxer.addTrack(format)
                trackPairs += index to outTrack
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    maxInputSize = maxOf(maxInputSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            if (trackPairs.isEmpty()) {
                muxer.release()
                extractor.release()
                return null
            }
            val startUs = startMs.toLong() * 1000L
            val endUs = endMs.toLong() * 1000L
            val buffer = ByteBuffer.allocateDirect(maxInputSize.coerceAtMost(8 * 1024 * 1024))
            val info = MediaCodecBufferInfoCompat()
            for ((inTrack, _) in trackPairs) extractor.unselectTrack(inTrack)
            muxer.start()
            for ((inTrack, outTrack) in trackPairs) {
                extractor.selectTrack(inTrack)
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                while (true) {
                    buffer.clear()
                    val sampleTime = extractor.sampleTime
                    if (sampleTime < 0 || sampleTime >= endUs) break
                    val size = extractor.readSampleData(buffer, 0)
                    if (size <= 0) break
                    info.set(
                        0,
                        size,
                        (sampleTime - startUs).coerceAtLeast(0L),
                        extractor.sampleFlags,
                    )
                    muxer.writeSampleData(outTrack, buffer, info.bufferInfo)
                    if (!extractor.advance()) break
                }
                extractor.unselectTrack(inTrack)
            }
            runCatching { muxer.stop() }
        } finally {
            runCatching { muxer.release() }
            runCatching { extractor.release() }
        }
        return output.takeIf { it.exists() && it.length() > 0 }
    }

    // region Mic Pro e-ink push (reverse-engineered TRC accessory protocol)

    /**
     * Pushes a weather card to the Insta360 Mic Pro transmitter over BLE using the
     * TRC accessory protocol. The frame layout is
     * [group][cmd][seq LE][len LE][payload][crc16] on service A.
     *
     * The numeric AppCmd codes are supplied by the caller: they are derived from a
     * capture of the official app (see micpro_ink/derive_codes.py) because the SDK
     * only ever logs command names.
     */
    /**
     * Converts a 240x208 weather card into the two payloads the Mic Pro expects:
     * a 4bpp indexed bitmap (24960 B) and a 240x240 six-colour PNG. Keeping the
     * conversion on-device means the app does not depend on external tooling.
     */
    // region Mic Pro e-ink transmitter (independent from the camera channel)

    /**
     * Scans for the Insta360 Mic Pro transmitter. The TX advertises as "2420A1" (the
     * trailing part of its serial) and exposes the TRC accessory service. This runs
     * on its own BLE path so the e-ink display can be driven without involving a
     * camera connection at all.
     */
    private fun scanMicPro(result: MethodChannel.Result) {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as android.bluetooth.BluetoothManager
        val adapter = manager.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.error("BLE_DISABLED", "Bluetooth is not enabled", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("BLE_SCANNER_UNAVAILABLE", "The BLE scanner is unavailable", null)
            return
        }
        val found = linkedMapOf<String, MutableMap<String, Any?>>()
        val finished = java.util.concurrent.atomic.AtomicBoolean(false)

        fun finish() {
            if (!finished.compareAndSet(false, true)) return
            runCatching { scanner.stopScan(micProScanCallback) }
            runOnUiThread { result.success(found.values.toList()) }
        }

        micProScanCallback = object : android.bluetooth.le.ScanCallback() {
            override fun onScanResult(callbackType: Int, result: android.bluetooth.le.ScanResult) {
                val record = result.scanRecord
                val name = record?.deviceName ?: result.device.name.orEmpty()
                val address = result.device.address
                // The TX advertises its serial tail; accept both the bare tail and the
                // full product name so the scan works across firmware variants.
                val looksLikeTx = name.contains("2420A1", true) ||
                    name.contains("Mic Pro", true) ||
                    name.contains("TRC", true)
                val hasTrcService = record?.serviceUuids
                    ?.any { it.uuid.toString().startsWith("e49a25f8", true) } == true
                if (!looksLikeTx && !hasTrcService) return
                found[address] = mutableMapOf(
                    "address" to address,
                    "name" to name,
                    "rssi" to result.rssi,
                    "hasTrcService" to hasTrcService,
                )
            }

            override fun onScanFailed(errorCode: Int) {
                if (!finished.compareAndSet(false, true)) return
                runOnUiThread { result.error("MICPRO_SCAN_FAILED", "scan failed code=$errorCode", null) }
            }
        }
        scanner.startScan(micProScanCallback)
        // Bounded scan window: the TX advertises frequently when awake.
        mainScope.launch {
            kotlinx.coroutines.delay(12_000L)
            finish()
        }
    }

    private var micProScanCallback: android.bluetooth.le.ScanCallback? = null
    private var micProGatt: android.bluetooth.BluetoothGatt? = null

    /**
     * Opens a GATT connection to the transmitter and reports its services, so the UI
     * can confirm the e-ink channel is reachable before pushing a wallpaper.
     */
    private fun connectMicPro(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>("address")
        if (address.isNullOrBlank()) {
            result.error("MICPRO_ADDRESS_EMPTY", "A Mic Pro Bluetooth address is required", null)
            return
        }
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as android.bluetooth.BluetoothManager
        val device = runCatching { manager.adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) {
            result.error("MICPRO_DEVICE_NOT_FOUND", "The transmitter is no longer reachable", null)
            return
        }
        val completed = java.util.concurrent.atomic.AtomicBoolean(false)
        micProGatt?.close()
        micProGatt = device.connectGatt(
            this,
            false,
            object : android.bluetooth.BluetoothGattCallback() {
                override fun onConnectionStateChange(
                    g: android.bluetooth.BluetoothGatt,
                    status: Int,
                    newState: Int,
                ) {
                    if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                        g.discoverServices()
                    } else if (completed.compareAndSet(false, true)) {
                        diagLog("micpro: gatt disconnected status=$status")
                        runOnUiThread { result.error("MICPRO_DISCONNECTED", "connection closed", null) }
                    }
                }

                override fun onServicesDiscovered(g: android.bluetooth.BluetoothGatt, status: Int) {
                    if (!completed.compareAndSet(false, true)) return
                    val services = g.services.map { service ->
                        mapOf(
                            "uuid" to service.uuid.toString(),
                            "characteristics" to service.characteristics.map { it.uuid.toString() },
                        )
                    }
                    val hasTrc = g.services.any {
                        it.uuid.toString().startsWith("e49a25f8", true)
                    }
                    diagLog("micpro: services=${services.size} trc=$hasTrc")
                    runOnUiThread {
                        emitNativeEvent(
                            "micpro_connected",
                            detail = if (hasTrc) "trc-ready" else "no-trc-service",
                        )
                        result.success(mapOf("services" to services, "hasTrcService" to hasTrc))
                    }
                }
            },
            android.bluetooth.BluetoothDevice.TRANSPORT_LE,
        )
        mainScope.launch {
            kotlinx.coroutines.delay(15_000L)
            if (completed.compareAndSet(false, true)) {
                runOnUiThread {
                    result.error("MICPRO_CONNECT_TIMEOUT", "Timed out connecting to the transmitter", null)
                }
            }
        }
    }

    // endregion

    /**
     * Probes the transmitter's protocol by sending candidate frames and recording
     * every notification it returns. This is how the numeric command ids and the
     * exact header layout get resolved: the device answers genuine requests, so the
     * reply's byte positions reveal the field order.
     */
    private fun probeMicPro(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>("address")
        if (address.isNullOrBlank()) {
            result.error("MICPRO_ADDRESS_EMPTY", "A Mic Pro Bluetooth address is required", null)
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching { MicProProbe(this@MainActivity).run(address) }
                .onSuccess { report ->
                    diagLog("micpro probe: $report")
                    runOnUiThread { result.success(report) }
                }
                .onFailure { error ->
                    diagLog("micpro probe failed: ${error.message}")
                    runOnUiThread { result.error("MICPRO_PROBE_FAILED", error.message, null) }
                }
        }
    }

    private fun prepareMicProPayloads(call: MethodCall, result: MethodChannel.Result) {
        val cardPath = call.argument<String>("cardPath")
        val cacheKey = call.argument<String>("cacheKey") ?: SystemClock.uptimeMillis().toString()
        if (cardPath.isNullOrBlank()) {
            result.error("CARD_PATH_EMPTY", "A weather card path is required", null)
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching { buildMicProPayloads(cardPath, cacheKey) }
                .onSuccess { value -> runOnUiThread { result.success(value) } }
                .onFailure { error ->
                    runOnUiThread { result.error("MICPRO_PREPARE_FAILED", error.message, null) }
                }
        }
    }

    /** Loads the card, dithers it to the measured six inks and writes both files. */
    private fun buildMicProPayloads(cardPath: String, cacheKey: String): Map<String, Any> {
        val source = android.graphics.BitmapFactory.decodeFile(cardPath)
            ?: error("Unable to decode the weather card at $cardPath")
        val width = 240
        val height = 208
        val scaled = android.graphics.Bitmap.createScaledBitmap(source, width, height, true)
        if (scaled !== source) source.recycle()

        // The six measured inks, in the order the device indexes them.
        val palette = arrayOf(
            intArrayOf(130, 20, 20),
            intArrayOf(50, 100, 70),
            intArrayOf(160, 160, 160),
            intArrayOf(0, 80, 150),
            intArrayOf(30, 30, 30),
            intArrayOf(160, 160, 0),
        )
        val pixels = IntArray(width * height)
        scaled.getPixels(pixels, 0, width, 0, 0, width, height)
        val indices = ByteArray(width * height)
        // Floyd-Steinberg error diffusion, matching the reference pipeline.
        val working = FloatArray(width * height * 3)
        for (i in pixels.indices) {
            working[i * 3] = ((pixels[i] shr 16) and 0xFF).toFloat()
            working[i * 3 + 1] = ((pixels[i] shr 8) and 0xFF).toFloat()
            working[i * 3 + 2] = (pixels[i] and 0xFF).toFloat()
        }
        for (y in 0 until height) {
            for (x in 0 until width) {
                val i = (y * width + x) * 3
                val r = working[i].coerceIn(0f, 255f)
                val g = working[i + 1].coerceIn(0f, 255f)
                val b = working[i + 2].coerceIn(0f, 255f)
                var best = 0
                var bestDistance = Float.MAX_VALUE
                for (p in palette.indices) {
                    val dr = r - palette[p][0]
                    val dg = g - palette[p][1]
                    val db = b - palette[p][2]
                    val distance = dr * dr + dg * dg + db * db
                    if (distance < bestDistance) {
                        bestDistance = distance
                        best = p
                    }
                }
                indices[y * width + x] = best.toByte()
                val er = r - palette[best][0]
                val eg = g - palette[best][1]
                val eb = b - palette[best][2]
                fun spread(px: Int, py: Int, factor: Float) {
                    if (px < 0 || px >= width || py < 0 || py >= height) return
                    val j = (py * width + px) * 3
                    working[j] += er * factor
                    working[j + 1] += eg * factor
                    working[j + 2] += eb * factor
                }
                spread(x + 1, y, 7f / 16f)
                spread(x - 1, y + 1, 3f / 16f)
                spread(x, y + 1, 5f / 16f)
                spread(x + 1, y + 1, 1f / 16f)
            }
        }

        // Phase 1: two pixels per byte, low nibble first.
        val packed = ByteArray(width * height / 2)
        for (i in packed.indices) {
            val low = indices[i * 2].toInt() and 0x0F
            val high = indices[i * 2 + 1].toInt() and 0x0F
            packed[i] = (low or (high shl 4)).toByte()
        }
        val bitmapFile = File(cacheDir, "micpro_${cacheKey}_4bpp.bin")
        bitmapFile.writeBytes(packed)

        // Phase 2: the six-colour PNG on a 240x240 canvas, padded with e-ink white.
        val canvasBitmap = android.graphics.Bitmap.createBitmap(240, 240, android.graphics.Bitmap.Config.ARGB_8888)
        canvasBitmap.eraseColor(android.graphics.Color.rgb(160, 160, 160))
        val quantised = IntArray(width * height)
        for (i in quantised.indices) {
            val p = indices[i].toInt() and 0x0F
            val ink = palette[p.coerceIn(0, palette.size - 1)]
            quantised[i] = android.graphics.Color.rgb(ink[0], ink[1], ink[2])
        }
        canvasBitmap.setPixels(quantised, 0, width, 0, 0, width, height)
        val metaFile = File(cacheDir, "micpro_${cacheKey}_6color.png")
        metaFile.outputStream().use { canvasBitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        canvasBitmap.recycle()
        scaled.recycle()

        return mapOf(
            "bitmapPath" to bitmapFile.absolutePath,
            "metaPath" to metaFile.absolutePath,
            "bitmapSize" to bitmapFile.length(),
            "metaSize" to metaFile.length(),
        )
    }

    private fun pushMicProWallpaper(call: MethodCall, result: MethodChannel.Result) {
        val bitmapPath = call.argument<String>("bitmapPath")
        val metaPath = call.argument<String>("metaPath")
        val codes = call.argument<Map<String, Any?>>("codes")
        val deviceAddress = call.argument<String>("address")
        if (bitmapPath.isNullOrBlank() || metaPath.isNullOrBlank()) {
            result.error("MICPRO_PATHS_EMPTY", "Both the bitmap and metadata paths are required", null)
            return
        }
        if (codes.isNullOrEmpty()) {
            result.error(
                "MICPRO_CODES_MISSING",
                "Command codes are required; run micpro_ink/derive_codes.py against a capture",
                null,
            )
            return
        }
        mainScope.launch(Dispatchers.IO) {
            runCatching {
                MicProPusher(this@MainActivity).push(
                    deviceAddress = deviceAddress,
                    bitmap = File(bitmapPath).readBytes(),
                    meta = File(metaPath).readBytes(),
                    codes = codes.mapValues { (it.value as Number).toInt() },
                )
            }.onSuccess {
                diagLog("micpro: wallpaper pushed")
                emitNativeEvent("micpro_pushed")
                runOnUiThread { result.success(null) }
            }.onFailure { error ->
                diagLog("micpro: push failed ${error.message}")
                emitNativeEvent("micpro_push_failed", error.message)
                runOnUiThread { result.error("MICPRO_PUSH_FAILED", error.message, null) }
            }
        }
    }

    // endregion

    private fun shareWallpaper(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("WALLPAPER_PATH_EMPTY", "Wallpaper path is empty", null)
            return
        }
        runCatching {
            val file = File(path)
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "选择 Insta360 App 导入 Mic Pro 壁纸"))
        }.onSuccess { result.success(null) }
            .onFailure { error -> result.error("WALLPAPER_SHARE_FAILED", error.message, null) }
    }

    private fun startPreview() {
        val camera = currentCamera ?: return
        if (!previewStarted) {
            previewStarted = true
            emitNativeEvent("preview_starting")
            mainScope.launch {
                var step = "lensType"
                runCatching {
                    // The SDK rejects functionMode changes until a valid lens type is
                    // selected, so mirror the official demo order: lensType first.
                    android.util.Log.d("DayWeather", "preview step: lensType")
                    val supportedLenses = camera.capture.lensType
                        .getSupported()
                        .getOrNull()
                        .orEmpty()
                        .filter { it != SensorMode.UNKNOWN }
                    val currentLens = camera.capture.lensType.getValue().getOrNull()
                    val lens = currentLens?.takeIf { supportedLenses.contains(it) }
                        ?: supportedLenses.firstOrNull()
                    if (lens != null && lens != currentLens) {
                        camera.capture.lensType.setValue(lens).getOrThrow()
                    }
                    android.util.Log.d("DayWeather", "preview lens=$lens")
                    step = "functionMode"
                    android.util.Log.d("DayWeather", "preview step: functionMode")
                    camera.capture.functionMode.setValue(FunctionMode.VIDEO_LIVE).getOrThrow()
                    step = "init"
                    android.util.Log.d("DayWeather", "preview step: init")
                    camera.preview.init(application)
                    step = "registerListener"
                    android.util.Log.d("DayWeather", "preview step: registerListener")
                    camera.preview.registerCameraStreamListener(streamListener)
                    step = "startStream"
                    android.util.Log.d("DayWeather", "preview step: startStream")
                    camera.preview.startStream()
                    android.util.Log.d("DayWeather", "preview step: startStream returned")
                }.onFailure {
                    previewStarted = false
                    android.util.Log.e("DayWeather", "preview failed at $step: ${it.message}", it)
                    emitNativeEvent("preview_failed", "$step: ${it.message}")
                }
            }
        }
        attachPreviewPlayer()
    }

    private fun attachPreviewPlayer() {
        val player = previewPlayer ?: return
        player.post {
            if (previewPlayer !== player) return@post
            player.setListener(playerViewListener)
            runCatching {
                player.destroyRender()
                player.prepare(PreviewParams())
                player.play()
            }.onFailure { emitNativeEvent("preview_failed", it.message) }
        }
    }

    private fun detachPreviewPlayer(player: InstaCapturePlayerView) {
        if (previewPlayer !== player) return
        stopPreviewFrameSampling()
        currentCamera?.preview?.setPipeline(null)
        previewPlayer = null
    }

    private fun stopPreview() {
        stopPreviewFrameSampling()
        val camera = currentCamera
        if (camera != null && previewStarted) {
            runCatching {
                camera.preview.unregisterCameraStreamListener(streamListener)
                camera.preview.setPipeline(null)
                camera.preview.stopStream()
            }
        }
        flushPendingAudioFrame()
        latestVideoTimestamp = null
        previewStarted = false
    }

    private fun startPreviewFrameSampling() {
        if (previewFrameSampling) return
        previewFrameSampling = true
        previewFrameHandler.removeCallbacks(previewFrameSampler)
        previewFrameHandler.post(previewFrameSampler)
    }

    private fun stopPreviewFrameSampling() {
        previewFrameSampling = false
        previewFrameHandler.removeCallbacks(previewFrameSampler)
    }

    private fun capturePreviewFrame() {
        val timestamp = latestVideoTimestamp ?: return
        val player = previewPlayer ?: return
        val texture = findTextureView(player) ?: return
        if (!texture.isAvailable || texture.width <= 0 || texture.height <= 0) return
        val targetWidth = 640
        val targetHeight = (texture.height * targetWidth.toFloat() / texture.width)
            .toInt()
            .coerceAtLeast(1)
        val bitmap = runCatching { texture.getBitmap(targetWidth, targetHeight) }.getOrNull()
            ?: return
        val output = ByteArrayOutputStream()
        runCatching {
            bitmap.compress(Bitmap.CompressFormat.JPEG, 68, output)
        }
        bitmap.recycle()
        val bytes = output.toByteArray()
        if (bytes.isNotEmpty()) {
            emitNativeEvent(
                "video_stream_frame",
                extra = mapOf(
                    "timestampMs" to timestamp,
                    "data" to bytes,
                ),
            )
        }
    }

    private fun findTextureView(view: View): TextureView? {
        if (view is TextureView) return view
        if (view !is ViewGroup) return null
        for (index in 0 until view.childCount) {
            findTextureView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun appendAudioFrame(streamData: PreviewStreamFrame) {
        val data = streamData.data
        if (data.isEmpty()) return
        var completedTimestamp: Long? = null
        var completedData: ByteArray? = null
        synchronized(audioFrameLock) {
            val timestamp = streamData.timestamp
            val currentTimestamp = pendingAudioTimestamp
            if (currentTimestamp != null && currentTimestamp != timestamp) {
                completedTimestamp = currentTimestamp
                completedData = pendingAudioBuffer.toByteArray()
                pendingAudioBuffer.reset()
            }
            if (pendingAudioTimestamp == null || currentTimestamp != timestamp) {
                pendingAudioTimestamp = timestamp
            }
            pendingAudioBuffer.write(data)
        }
        if (completedTimestamp != null && completedData != null) {
            emitAudioFrame(completedTimestamp!!, completedData!!)
        }
    }

    private fun flushPendingAudioFrame() {
        val timestamp: Long?
        val data: ByteArray
        synchronized(audioFrameLock) {
            timestamp = pendingAudioTimestamp
            data = pendingAudioBuffer.toByteArray()
            pendingAudioTimestamp = null
            pendingAudioBuffer.reset()
        }
        if (timestamp != null && data.isNotEmpty()) emitAudioFrame(timestamp!!, data)
    }

    private fun emitAudioFrame(timestamp: Long, data: ByteArray) {
        audioFrameCount += 1
        audioByteCount += data.size
        if (audioFrameCount == 1L || audioFrameCount % 25L == 0L) {
            android.util.Log.d(
                "DayWeather",
                "audio frame #$audioFrameCount bytes=$audioByteCount ts=$timestamp",
            )
        }
        emitNativeEvent(
            "audio_stream",
            extra = mapOf(
                "timestampMs" to timestamp,
                "frameIndex" to audioFrameCount,
                "byteCount" to audioByteCount,
                "data" to data,
            ),
        )
    }

    private val streamListener = object : CameraStreamListener {
        override fun onOpening() = Unit

        override fun onOpened() {
            val player = previewPlayer ?: return
            player.post {
                if (previewPlayer !== player) return@post
                runCatching {
                    player.destroyRender()
                    player.prepare(PreviewParams())
                    player.play()
                }.onFailure { emitNativeEvent("preview_failed", it.message) }
            }
        }

        override fun onIdle() = Unit

        override fun onParamsChanged(paramsUpdate: PreviewStreamParamsUpdate) = Unit

        override fun onStreamDataNotify(streamData: PreviewStreamFrame) {
            if (streamData.type.isVideo) {
                latestVideoTimestamp = streamData.timestamp
            }
            if (streamData.type == com.arashivision.sdk.camera.api.preview.PreviewStreamType.AUDIO) {
                appendAudioFrame(streamData)
            }
        }
    }

    private val playerViewListener = object : PlayerViewListener {
        override fun onLoadingStatusChanged(isLoading: Boolean) = Unit

        override fun onLoadingFinish() {
            val camera = currentCamera ?: return
            val pipeline = previewPlayer?.getPipeline() ?: return
            camera.preview.setPipeline(pipeline)
            runCatching { camera.preview.requestStreamIframe() }
        }

        override fun onFail(exception: InstaException) {
            emitNativeEvent("preview_failed", exception.message)
        }

        override fun onFirstFrameRendered() {
            startPreviewFrameSampling()
            emitNativeEvent("preview_ready")
        }

        override fun onReleaseCameraPipeline() {
            currentCamera?.preview?.setPipeline(null)
        }
    }

    private class GoPreviewFactory(private val activity: MainActivity) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView = GoPreviewView(activity)
    }

    private class GoPreviewView(private val activity: MainActivity) : PlatformView {
        private val container = FrameLayout(activity)
        private val player = InstaCapturePlayerView(activity)

        init {
            player.setLifecycle(activity.lifecycle)
            container.addView(
                player,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    Gravity.CENTER,
                ),
            )
            activity.previewPlayer = player
            activity.startPreview()
        }

        override fun getView(): View = container

        override fun dispose() {
            activity.detachPreviewPlayer(player)
            player.setListener(null)
            player.destroy()
        }
    }

    private class MediaCodecBufferInfoCompat {
        val bufferInfo = android.media.MediaCodec.BufferInfo()

        fun set(offset: Int, size: Int, presentationTimeUs: Long, flags: Int) {
            bufferInfo.set(offset, size, presentationTimeUs, flags)
        }
    }
}

/**
 * Minimal GATT client for the Insta360 Mic Pro transmitter. It speaks the TRC
 * accessory protocol: a little-endian segment/cmd/sequence/length header followed
 * by a payload, sent on service A's write characteristic with acknowledgements read
 * from the matching notify characteristic.
 *
 * UUIDs and sizes come from a live GATT enumeration of the device
 * (see micpro_ink/REVERSE_INTEGRATION.md).
 */
private class MicProPusher(private val context: android.content.Context) {
    private val serviceUuid = java.util.UUID.fromString("e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1")
    private val writeUuid = java.util.UUID.fromString("e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1")
    private val notifyUuid = java.util.UUID.fromString("e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1")

    companion object {
        private const val PACKET_SIZE = 221
        private const val FRAME_HEADER_SIZE = 7
        private const val FILE_CHUNK_SIZE = 212
        private const val FILE_CHUNK_HEADER_SIZE = 2
        private const val ACK_TIMEOUT_MS = 3_000L
        private const val SEGMENT_SINGLE = 0x08
    }

    private val ready = java.util.concurrent.CountDownLatch(1)
    private var failure: Throwable? = null
    private var gatt: android.bluetooth.BluetoothGatt? = null
    private val acks = java.util.concurrent.LinkedBlockingQueue<ByteArray>()
    private val descriptorStatuses = java.util.concurrent.LinkedBlockingQueue<Int>()

    private val callback = object : android.bluetooth.BluetoothGattCallback() {
        override fun onConnectionStateChange(g: android.bluetooth.BluetoothGatt, status: Int, newState: Int) {
            gatt = g
            if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else {
                failure = IllegalStateException("GATT disconnected (status=$status)")
                ready.countDown()
            }
        }

        override fun onServicesDiscovered(g: android.bluetooth.BluetoothGatt, status: Int) {
            if (status != android.bluetooth.BluetoothGatt.GATT_SUCCESS) {
                failure = IllegalStateException("service discovery failed (status=$status)")
                ready.countDown()
                return
            }
            g.requestMtu(247)
        }

        override fun onMtuChanged(g: android.bluetooth.BluetoothGatt, mtu: Int, status: Int) {
            ready.countDown()
        }

        override fun onDescriptorWrite(
            g: android.bluetooth.BluetoothGatt,
            descriptor: android.bluetooth.BluetoothGattDescriptor,
            status: Int,
        ) {
            descriptorStatuses.offer(status)
        }

        override fun onCharacteristicChanged(
            g: android.bluetooth.BluetoothGatt,
            characteristic: android.bluetooth.BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            acks.offer(value)
        }
    }

    fun push(
        deviceAddress: String?,
        bitmap: ByteArray,
        meta: ByteArray,
        codes: Map<String, Int>,
    ) {
        val manager = context.getSystemService(android.content.Context.BLUETOOTH_SERVICE)
            as android.bluetooth.BluetoothManager
        val adapter = manager.adapter
            ?: throw IllegalStateException("Bluetooth is unavailable")
        val device = deviceAddress
            ?.let { adapter.getRemoteDevice(it) }
            ?: throw IllegalStateException("A Mic Pro Bluetooth address is required")

        val connection = device.connectGatt(context, false, callback, android.bluetooth.BluetoothDevice.TRANSPORT_LE)
        try {
            if (!ready.await(15, java.util.concurrent.TimeUnit.SECONDS)) {
                throw IllegalStateException("Timed out while connecting to the Mic Pro")
            }
            failure?.let { throw it }
            val g = gatt ?: throw IllegalStateException("No GATT connection")

            val service = g.getService(serviceUuid)
                ?: throw IllegalStateException("The Mic Pro wallpaper service was not found")
            val write = service.getCharacteristic(writeUuid)
                ?: throw IllegalStateException("The Mic Pro write characteristic was not found")
            val notify = service.getCharacteristic(notifyUuid)
            if (notify != null) {
                g.setCharacteristicNotification(notify, true)
                val descriptor = notify.getDescriptor(java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
                if (descriptor != null) {
                    descriptor.value = android.bluetooth.BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    if (!g.writeDescriptor(descriptor)) {
                        throw IllegalStateException("Failed to enable Mic Pro notifications")
                    }
                    val descriptorStatus = descriptorStatuses.poll(
                        ACK_TIMEOUT_MS,
                        java.util.concurrent.TimeUnit.MILLISECONDS,
                    )
                    if (descriptorStatus != android.bluetooth.BluetoothGatt.GATT_SUCCESS) {
                        throw IllegalStateException("Mic Pro notification setup failed (status=$descriptorStatus)")
                    }
                }
            }

            // Phase 1 announces the bitmap, phase 2 delivers it, matching the
            // two-stage flow the official app uses.
            sendCommand(g, write, codes, "TRC_APP_CMD_READY_WALLPAPER", EMPTY_PAYLOAD)
            upload(g, write, codes, "APP_CMD_WRITE_FILE_BEGIN", bitmap)
            upload(g, write, codes, "APP_CMD_WRITE_FILE_BEGIN", meta)
            sendCommand(g, write, codes, "APP_CMD_WRITE_FILE_CANCEL", EMPTY_PAYLOAD)
            sendCommand(g, write, codes, "TRC_APP_CMD_GET_WALLPAPER", EMPTY_PAYLOAD)
        } finally {
            runCatching { connection.disconnect() }
            runCatching { connection.close() }
        }
    }

    private val EMPTY_PAYLOAD = ByteArray(0)

    /** Sends the file header (begin) then the payload split across 212-byte chunks. */
    private fun upload(
        g: android.bluetooth.BluetoothGatt,
        write: android.bluetooth.BluetoothGattCharacteristic,
        codes: Map<String, Int>,
        beginCommand: String,
        data: ByteArray,
    ) {
        val header = ByteArray(8)
        header[0] = (data.size and 0xFF).toByte()
        header[1] = ((data.size ushr 8) and 0xFF).toByte()
        header[2] = ((data.size ushr 16) and 0xFF).toByte()
        header[3] = ((data.size ushr 24) and 0xFF).toByte()
        sendCommand(g, write, codes, beginCommand, header)
        var offset = 0
        var fileSequence = 0
        while (offset < data.size) {
            val chunk = data.copyOfRange(offset, minOf(offset + FILE_CHUNK_SIZE, data.size))
            val fileChunk = ByteArray(FILE_CHUNK_HEADER_SIZE + chunk.size)
            fileChunk[0] = (fileSequence and 0xFF).toByte()
            fileChunk[1] = ((fileSequence ushr 8) and 0xFF).toByte()
            chunk.copyInto(fileChunk, FILE_CHUNK_HEADER_SIZE)
            sendCommand(g, write, codes, "APP_CMD_WRITE_FILE_DATA", fileChunk)
            offset += chunk.size
            fileSequence += 1
        }
        sendCommand(g, write, codes, "APP_CMD_WRITE_FILE_END", EMPTY_PAYLOAD)
    }

    private var sequence = 0

    /** Wraps [payload] in the TRC frame and waits for the device acknowledgement. */
    private fun sendCommand(
        g: android.bluetooth.BluetoothGatt,
        write: android.bluetooth.BluetoothGattCharacteristic,
        codes: Map<String, Int>,
        name: String,
        payload: ByteArray,
    ) {
        val cmd = codes[name]
            ?: throw IllegalStateException("Missing command code for $name")
        if (payload.size > PACKET_SIZE - FRAME_HEADER_SIZE) {
            throw IllegalArgumentException("Payload for $name is too large: ${payload.size} bytes")
        }
        sequence = (sequence + 1) and 0xFFFF
        while (acks.poll() != null) Unit
        val frame = ByteArray(FRAME_HEADER_SIZE + payload.size)
        frame[0] = SEGMENT_SINGLE.toByte()
        frame[1] = (cmd and 0xFF).toByte()
        frame[2] = ((cmd ushr 8) and 0xFF).toByte()
        frame[3] = (sequence and 0xFF).toByte()
        frame[4] = ((sequence ushr 8) and 0xFF).toByte()
        frame[5] = (payload.size and 0xFF).toByte()
        frame[6] = ((payload.size ushr 8) and 0xFF).toByte()
        payload.copyInto(frame, FRAME_HEADER_SIZE)
        write.value = frame
        write.writeType = if (write.properties and android.bluetooth.BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            android.bluetooth.BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            android.bluetooth.BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        if (!g.writeCharacteristic(write)) {
            throw IllegalStateException("Failed to write $name")
        }
        if (acks.poll(ACK_TIMEOUT_MS, java.util.concurrent.TimeUnit.MILLISECONDS) == null) {
            throw IllegalStateException("Timed out waiting for $name acknowledgement")
        }
    }
}

/**
 * Sends candidate protocol frames to the Mic Pro and captures every notification the
 * device returns. The accessory protocol only logs command *names*, so the numeric
 * ids have to be recovered from real traffic; this probe provides that traffic.
 */
private class MicProProbe(private val context: android.content.Context) {
    private val serviceUuid = java.util.UUID.fromString("e49a25f8-f69a-11e8-8eb2-f2801f1b9fd1")
    private val writeUuid = java.util.UUID.fromString("e49a25e0-f69a-11e8-8eb2-f2801f1b9fd1")
    private val notifyUuid = java.util.UUID.fromString("e49a28e1-f69a-11e8-8eb2-f2801f1b9fd1")

    private val ready = java.util.concurrent.CountDownLatch(1)
    private val replies = java.util.Collections.synchronizedList(mutableListOf<String>())
    private var failure: Throwable? = null

    private val callback = object : android.bluetooth.BluetoothGattCallback() {
        override fun onConnectionStateChange(g: android.bluetooth.BluetoothGatt, status: Int, newState: Int) {
            if (newState == android.bluetooth.BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else if (status != android.bluetooth.BluetoothGatt.GATT_SUCCESS) {
                failure = IllegalStateException("disconnected status=$status")
                ready.countDown()
            }
        }

        override fun onServicesDiscovered(g: android.bluetooth.BluetoothGatt, status: Int) {
            g.requestMtu(247)
        }

        override fun onMtuChanged(g: android.bluetooth.BluetoothGatt, mtu: Int, status: Int) {
            ready.countDown()
        }

        override fun onCharacteristicChanged(
            g: android.bluetooth.BluetoothGatt,
            characteristic: android.bluetooth.BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            replies.add(value.joinToString("") { "%02x".format(it) })
        }
    }

    /**
     * Sweeps candidate command ids on the write characteristic. A reply to any of
     * them confirms both the channel and the header layout (cmd then seq then len).
     */
    fun run(address: String): Map<String, Any?> {
        val manager = context.getSystemService(android.content.Context.BLUETOOTH_SERVICE)
            as android.bluetooth.BluetoothManager
        val device = manager.adapter?.getRemoteDevice(address)
            ?: throw IllegalStateException("the transmitter is not reachable")
        val connection = device.connectGatt(context, false, callback, android.bluetooth.BluetoothDevice.TRANSPORT_LE)
        try {
            if (!ready.await(15, java.util.concurrent.TimeUnit.SECONDS)) {
                throw IllegalStateException("timed out connecting")
            }
            failure?.let { throw it }
            val g = connection
            val service = g.getService(serviceUuid)
                ?: throw IllegalStateException("the e-ink service is missing")
            val write = service.getCharacteristic(writeUuid)
                ?: throw IllegalStateException("the write characteristic is missing")
            val notify = service.getCharacteristic(notifyUuid)
            if (notify != null) {
                g.setCharacteristicNotification(notify, true)
                notify.getDescriptor(java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
                    ?.let { descriptor ->
                        descriptor.value = android.bluetooth.BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        g.writeDescriptor(descriptor)
                    }
            }
            val attempted = mutableListOf<Int>()
            // Sweep plausible ids with a minimal 6-byte header and empty payload.
            for (cmd in 1..48) {
                val frame = byteArrayOf(0x08, cmd.toByte(), 0x01, 0x00, 0x00, 0x00)
                write.value = frame
                write.writeType = android.bluetooth.BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                if (runCatching { g.writeCharacteristic(write) }.getOrDefault(false)) {
                    attempted.add(cmd)
                }
                Thread.sleep(120)
            }
            Thread.sleep(1_500)
            return mapOf(
                "attempted" to attempted.size,
                "replies" to replies.toList(),
                "replyCount" to replies.size,
            )
        } finally {
            runCatching { connection.disconnect() }
            runCatching { connection.close() }
        }
    }
}
