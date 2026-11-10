package com.drmx86.vhscam

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.view.Surface
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Encodes already-processed frames (drawn onto the encoder's input surface) plus microphone audio
 * to an H.264/AAC MP4 in Movies/VHS Cam.
 */
class Recorder(private val ctx: Context, width: Int, height: Int, withAudio: Boolean) {
    private val w = width and 1.inv()
    private val h = height and 1.inv()
    private val baseUs = System.nanoTime() / 1000

    private val uri = ctx.contentResolver.insert(
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
        ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME,
                "VHS_" + SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(Date()) + ".mp4")
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/VHS Cam")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        })!!
    private val pfd: ParcelFileDescriptor = ctx.contentResolver.openFileDescriptor(uri, "w")!!
    private val muxer = MediaMuxer(pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

    private val vCodec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val surface: Surface
    private var aCodec: MediaCodec? = null
    private var audioRecord: AudioRecord? = null

    private val lock = Object()
    private var expectedTracks = 1
    private var addedTracks = 0
    private var muxerStarted = false
    private var vTrack = -1
    private var aTrack = -1
    @Volatile private var stopping = false
    private val threads = mutableListOf<Thread>()

    init {
        val vf = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, w * h * 10)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        vCodec.configure(vf, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = vCodec.createInputSurface()
        vCodec.start()
        threads += Thread({ videoLoop() }, "vhs-video-drain").also { it.start() }

        if (withAudio) startAudio()
    }

    @Suppress("MissingPermission")
    private fun startAudio() {
        val rate = 44100
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.CAMCORDER, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, 16384))
        } catch (e: Exception) { return }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val af = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 64000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        codec.configure(af, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        aCodec = codec
        audioRecord = rec
        synchronized(lock) { expectedTracks = 2 }
        threads += Thread({ audioLoop(rec, codec, rate) }, "vhs-audio").also { it.start() }
    }

    /** Draws one processed frame; called from the analysis thread. */
    fun submit(bmp: Bitmap) {
        if (stopping) return
        try {
            val c = surface.lockHardwareCanvas()
            c.drawBitmap(bmp, null, Rect(0, 0, w, h), null)
            surface.unlockCanvasAndPost(c)
        } catch (_: Exception) { /* surface gone while stopping */ }
    }

    private fun videoLoop() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            if (drain(vCodec, info, video = true)) break
        }
    }

    private fun audioLoop(rec: AudioRecord, codec: MediaCodec, rate: Int) {
        val info = MediaCodec.BufferInfo()
        val tmp = ByteArray(4096)
        var samples = 0L
        var startUs = -1L
        rec.startRecording()
        while (!stopping) {
            val n = rec.read(tmp, 0, tmp.size)
            if (n <= 0) continue
            if (startUs < 0) startUs = maxOf(0L, System.nanoTime() / 1000 - baseUs - n / 2 * 1_000_000L / rate)
            val pts = startUs + samples * 1_000_000L / rate
            val idx = codec.dequeueInputBuffer(10_000)
            if (idx >= 0) {
                val buf = codec.getInputBuffer(idx)!!
                buf.clear(); buf.put(tmp, 0, n)
                codec.queueInputBuffer(idx, 0, n, pts, 0)
                samples += n / 2
            }
            drain(codec, info, video = false)
        }
        rec.stop()
        // signal end of stream
        while (true) {
            val idx = codec.dequeueInputBuffer(10_000)
            if (idx >= 0) {
                codec.queueInputBuffer(idx, 0, 0, startUs.coerceAtLeast(0) + samples * 1_000_000L / rate,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                break
            }
        }
        while (!drain(codec, info, video = false)) { /* wait for EOS */ }
    }

    /** Returns true once the codec has signalled end of stream. */
    private fun drain(codec: MediaCodec, info: MediaCodec.BufferInfo, video: Boolean): Boolean {
        while (true) {
            val i = codec.dequeueOutputBuffer(info, 10_000)
            when {
                i == MediaCodec.INFO_TRY_AGAIN_LATER -> return false
                i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(codec.outputFormat, video)
                i >= 0 -> {
                    val buf: ByteBuffer = codec.getOutputBuffer(i)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0) {
                        if (video) info.presentationTimeUs = maxOf(0L, info.presentationTimeUs - baseUs)
                        buf.position(info.offset); buf.limit(info.offset + info.size)
                        synchronized(lock) {
                            while (!muxerStarted) lock.wait(50)
                            muxer.writeSampleData(if (video) vTrack else aTrack, buf, info)
                        }
                    }
                    codec.releaseOutputBuffer(i, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return true
                }
            }
        }
    }

    private fun addTrack(format: MediaFormat, video: Boolean) {
        synchronized(lock) {
            val t = muxer.addTrack(format)
            if (video) vTrack = t else aTrack = t
            addedTracks++
            if (addedTracks == expectedTracks) { muxer.start(); muxerStarted = true; lock.notifyAll() }
        }
    }

    /** Blocking; call off the main/analysis thread. Returns true if the file was saved. */
    fun stop(): Boolean {
        stopping = true
        try { vCodec.signalEndOfInputStream() } catch (_: Exception) {}
        threads.forEach { it.join(3000) }
        var ok = true
        try { synchronized(lock) { if (muxerStarted) muxer.stop() else ok = false } } catch (_: Exception) { ok = false }
        listOf<MediaCodec?>(vCodec, aCodec).forEach { try { it?.stop(); it?.release() } catch (_: Exception) {} }
        try { audioRecord?.release() } catch (_: Exception) {}
        try { muxer.release() } catch (_: Exception) {}
        try { surface.release() } catch (_: Exception) {}
        try { pfd.close() } catch (_: Exception) {}
        if (ok) {
            ctx.contentResolver.update(uri, ContentValues().apply {
                put(MediaStore.Video.Media.IS_PENDING, 0)
            }, null, null)
        } else {
            ctx.contentResolver.delete(uri, null, null)
        }
        return ok
    }
}
