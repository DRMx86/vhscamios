package com.drmx86.vhscam

import java.nio.ByteBuffer

/** JNI wrapper around the shared Rust ntsc-rs core (RGBA8, processed in place). */
object Ntsc {
    init { System.loadLibrary("ntsc_android") }

    external fun create(): Long
    external fun destroy(handle: Long)
    external fun setParams(handle: Long, grain: Float, color: Float, tracking: Float, softness: Float, tape: Int)
    external fun process(handle: Long, buffer: ByteBuffer, width: Int, height: Int, rowBytes: Int, frame: Long): Int
}
