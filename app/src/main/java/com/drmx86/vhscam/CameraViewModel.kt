package com.drmx86.vhscam

import android.Manifest
import android.app.Application
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Environment
import android.provider.MediaStore
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

data class Look(
    val name: String, val grain: Float, val color: Float,
    val tracking: Float, val softness: Float, val tape: Int, // 0 = SP, 1 = LP, 2 = EP
)

class CameraViewModel(app: Application) : AndroidViewModel(app) {

    companion object {
        // Same presets as the iOS / macOS apps (including RetroDann / RetroDann2).
        val looks = listOf(
            Look("Classic", 0.45f, 1.00f, 0.45f, 0.45f, 1),
            Look("Clean SP", 0.15f, 0.85f, 0.15f, 0.25f, 0),
            Look("Home Video", 0.25f, 1.15f, 0.10f, 0.30f, 0),
            Look("RetroDann", 0.80f, 0.55f, 0.24f, 0.35f, 0),
            Look("RetroDann2", 0.27f, 0.44f, 0.15f, 0.55f, 0),
            Look("Muted", 0.35f, 0.45f, 0.35f, 0.50f, 1),
            Look("B&W", 0.50f, 0.00f, 0.35f, 0.40f, 1),
            Look("Worn Tape", 0.80f, 0.80f, 0.85f, 0.70f, 2),
        )
    }

    // ---- UI state ----
    var frame by mutableStateOf<ImageBitmap?>(null); private set
    var grain by mutableFloatStateOf(0.45f); private set
    var color by mutableFloatStateOf(1.0f); private set
    var tracking by mutableFloatStateOf(0.45f); private set
    var softness by mutableFloatStateOf(0.45f); private set
    var selectedLook by mutableIntStateOf(0); private set      // -1 = custom
    var useBack by mutableStateOf(true); private set           // back camera is the default
    var hd by mutableStateOf(false); private set
    var photoMode by mutableStateOf(false); private set
    var recording by mutableStateOf(false); private set
    var seconds by mutableIntStateOf(0); private set
    var message by mutableStateOf<String?>(null); private set

    // ---- engine ----
    private val handle = Ntsc.create()
    private val executor = Executors.newSingleThreadExecutor()
    private var tape = 1
    private var analysis: ImageAnalysis? = null
    private var rotation = Surface.ROTATION_0
    private var frameCounter = 0L
    private var buffer: ByteBuffer? = null

    @Volatile private var wantsRecording = false
    @Volatile private var wantsPhoto = false
    private var recorder: Recorder? = null   // analysis thread only

    init { select(0) }

    override fun onCleared() {
        executor.execute { Ntsc.destroy(handle) }
        executor.shutdown()
    }

    // ---- looks / sliders ----
    fun select(index: Int) {
        val l = looks[index]
        grain = l.grain; color = l.color; tracking = l.tracking; softness = l.softness; tape = l.tape
        selectedLook = index
        push()
    }
    fun updateGrain(v: Float) { grain = v; custom() }
    fun updateColor(v: Float) { color = v; custom() }
    fun updateTracking(v: Float) { tracking = v; custom() }
    fun updateSoftness(v: Float) { softness = v; custom() }
    private fun custom() { selectedLook = -1; push() }
    private fun push() = Ntsc.setParams(handle, grain, color, tracking, softness, tape)

    // ---- camera ----
    fun switchCamera() { if (!recording) useBack = !useBack }
    fun setHD(value: Boolean) { if (!recording) hd = value }
    fun toggleMode() { if (!recording) photoMode = !photoMode }

    /** Called from the OrientationEventListener. Locked while recording (frame size must stay constant). */
    fun setRotation(r: Int) {
        rotation = r
        if (!recording) analysis?.targetRotation = r
    }

    fun bind(context: Context, owner: LifecycleOwner) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val provider = future.get()
            val target = if (hd) Size(1280, 720) else Size(640, 480)
            val ia = ImageAnalysis.Builder()
                .setResolutionSelector(
                    ResolutionSelector.Builder().setResolutionStrategy(
                        ResolutionStrategy(target, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
                    ).build())
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            ia.targetRotation = rotation
            ia.setAnalyzer(executor, ::analyze)
            provider.unbindAll()
            val selector = if (useBack) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
            try {
                provider.bindToLifecycle(owner, selector, ia)
                analysis = ia
            } catch (e: Exception) {
                toast("Camera unavailable")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    // ---- frame pipeline (analysis thread) ----
    private fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes[0]
            val w = image.width
            val h = image.height
            val stridePx = plane.rowStride / 4

            // Copy into a bitmap, cropping row padding and rotating upright so the VHS head-switching
            // band always lands at the bottom of the picture (never mirrored, like the iOS app).
            val src = Bitmap.createBitmap(stridePx, h, Bitmap.Config.ARGB_8888)
            plane.buffer.rewind()
            src.copyPixelsFromBuffer(plane.buffer)
            val m = Matrix().apply { postRotate(image.imageInfo.rotationDegrees.toFloat()) }
            var out = Bitmap.createBitmap(src, 0, 0, w, h, m, false)
            if (!out.isMutable) out = out.copy(Bitmap.Config.ARGB_8888, true)
            if (out !== src) src.recycle()

            val bytes = out.width * out.height * 4
            var buf = buffer
            if (buf == null || buf.capacity() != bytes) {
                buf = ByteBuffer.allocateDirect(bytes); buffer = buf
            }
            buf!!.rewind(); out.copyPixelsToBuffer(buf)
            Ntsc.process(handle, buf, out.width, out.height, out.width * 4, frameCounter++)
            buf.rewind(); out.copyPixelsFromBuffer(buf)

            frame = out.asImageBitmap()
            handleRecording(out)
            if (wantsPhoto) { wantsPhoto = false; savePhoto(out) }
        } catch (e: Exception) {
            // drop the frame
        } finally {
            image.close()
        }
    }

    // ---- photo ----
    fun takePhoto() { wantsPhoto = true }

    private fun savePhoto(bmp: Bitmap) {
        val ctx = getApplication<Application>()
        val name = "VHS_" + SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(Date()) + ".jpg"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/VHS Cam")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = ctx.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        if (uri == null) { toast("Couldn't save photo"); return }
        try {
            ctx.contentResolver.openOutputStream(uri)!!.use { bmp.compress(Bitmap.CompressFormat.JPEG, 95, it) }
            values.clear(); values.put(MediaStore.Images.Media.IS_PENDING, 0)
            ctx.contentResolver.update(uri, values, null, null)
            toast("Photo saved")
        } catch (e: Exception) {
            ctx.contentResolver.delete(uri, null, null)
            toast("Couldn't save photo")
        }
    }

    // ---- video ----
    fun toggleRecording() { if (recording) stopRecording() else startRecording() }

    private fun startRecording() {
        recording = true
        seconds = 0
        wantsRecording = true
        viewModelScope.launch {
            while (recording) { delay(1000); if (recording) seconds++ }
        }
    }

    fun stopRecording() {
        if (!recording) return
        recording = false
        wantsRecording = false
        analysis?.targetRotation = rotation   // orientation may have changed while locked
    }

    private fun handleRecording(bmp: Bitmap) {
        if (wantsRecording && recorder == null) {
            val audio = ContextCompat.checkSelfPermission(
                getApplication(), Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
            try {
                recorder = Recorder(getApplication(), bmp.width, bmp.height, audio)
            } catch (e: Exception) {
                wantsRecording = false
                recording = false
                toast("Couldn't start recording")
            }
        }
        val r = recorder ?: return
        if (!wantsRecording) {
            recorder = null
            Thread {
                val ok = r.stop()
                toast(if (ok) "Video saved to Movies/VHS Cam" else "Recording failed")
            }.start()
        } else {
            r.submit(bmp)
        }
    }

    private fun toast(text: String) {
        message = text
        viewModelScope.launch {
            delay(2500)
            if (message == text) message = null
        }
    }
}
