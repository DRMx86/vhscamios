package com.drmx86.vhscam

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.view.OrientationEventListener
import android.view.Surface
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.FlipCameraAndroid
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

class MainActivity : ComponentActivity() {
    private val vm: CameraViewModel by viewModels()
    private lateinit var orientation: OrientationEventListener

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Follow how the phone is held so the VHS band stays at the bottom of the picture.
        orientation = object : OrientationEventListener(this) {
            override fun onOrientationChanged(o: Int) {
                if (o == ORIENTATION_UNKNOWN) return
                vm.setRotation(when {
                    o >= 315 || o < 45 -> Surface.ROTATION_0
                    o < 135 -> Surface.ROTATION_270
                    o < 225 -> Surface.ROTATION_180
                    else -> Surface.ROTATION_90
                })
            }
        }
        setContent { VHSApp(vm) }
    }

    override fun onStart() { super.onStart(); orientation.enable() }
    override fun onStop() { super.onStop(); orientation.disable() }
}

private val mono = FontFamily.Monospace

@Composable
fun VHSApp(vm: CameraViewModel) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        granted = it[Manifest.permission.CAMERA] == true
    }
    LaunchedEffect(Unit) {
        if (!granted) launcher.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
    }
    LaunchedEffect(granted, vm.useBack, vm.hd) { if (granted) vm.bind(context, owner) }
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_STOP) vm.stopRecording() }
        owner.lifecycle.addObserver(obs)
        onDispose { owner.lifecycle.removeObserver(obs) }
    }

    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    var showTape by remember { mutableStateOf(true) }

    MaterialTheme(colorScheme = darkColorScheme()) {
        Box(Modifier.fillMaxSize().background(Color.Black).systemBarsPadding()) {
            if (!granted) {
                Text("Camera access needed. Enable it in Settings > Apps > VHS Cam > Permissions.",
                    Modifier.align(Alignment.Center).padding(32.dp), color = Color.White)
            } else if (landscape) {
                Row(Modifier.fillMaxSize()) {
                    Column(Modifier.weight(1f)) { TopBar(vm); Preview(vm, Modifier.weight(1f)) }
                    Controls(vm, showTape, { showTape = !showTape },
                        Modifier.width(330.dp).verticalScroll(rememberScrollState()))
                }
            } else {
                Column(Modifier.fillMaxSize()) {
                    TopBar(vm)
                    Preview(vm, Modifier.weight(1f))
                    Controls(vm, showTape, { showTape = !showTape }, Modifier)
                }
            }
            vm.message?.let {
                Text(it, Modifier.align(Alignment.Center).clip(RoundedCornerShape(50))
                    .background(Color(0xCC222222)).padding(horizontal = 14.dp, vertical = 8.dp),
                    color = Color.White, fontFamily = mono, fontSize = 14.sp)
            }
        }
    }
}

@Composable
private fun TopBar(vm: CameraViewModel) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(10.dp).clip(CircleShape).background(if (vm.recording) Color.Red else Color.Gray))
        Spacer(Modifier.width(6.dp))
        Text(if (vm.recording) "REC %02d:%02d".format(vm.seconds / 60, vm.seconds % 60) else "STBY",
            color = Color.White, fontFamily = mono, fontWeight = FontWeight.Bold)
        Spacer(Modifier.weight(1f))
        Text(if (vm.hd) "720p" else "480p", color = if (vm.recording) Color.Gray else Color.White,
            fontFamily = mono, modifier = Modifier.clickable(enabled = !vm.recording) { vm.setHD(!vm.hd) }.padding(8.dp))
    }
}

@Composable
private fun Preview(vm: CameraViewModel, modifier: Modifier) {
    Box(modifier.fillMaxWidth().background(Color.Black)) {
        vm.frame?.let {
            Image(it, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
    }
}

@Composable
private fun Controls(vm: CameraViewModel, showTape: Boolean, toggleTape: () -> Unit, modifier: Modifier) {
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(CameraViewModel.looks) { i, look ->
                val sel = vm.selectedLook == i
                Text(look.name, fontFamily = mono, fontWeight = FontWeight.SemiBold, fontSize = 13.sp,
                    color = if (sel) Color.Black else Color.White,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(if (sel) Color.White else Color(0x26FFFFFF))
                        .clickable { vm.select(i) }
                        .padding(horizontal = 12.dp, vertical = 7.dp))
            }
        }
        if (showTape) {
            TapeSlider("GRAIN", vm.grain, 0f..1f, vm::setGrain)
            TapeSlider("COLOR", vm.color, 0f..1.5f, vm::setColor)
            TapeSlider("DISTORTION", vm.tracking, 0f..1f, vm::setTracking)
            TapeSlider("SOFTNESS", vm.softness, 0f..1f, vm::setSoftness)
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f)) {
                SmallButton(if (vm.photoMode) Icons.Filled.CameraAlt else Icons.Filled.Videocam,
                    if (vm.photoMode) "PHOTO" else "VIDEO") { vm.toggleMode() }
                SmallButton(Icons.Filled.Tune, "TAPE") { toggleTape() }
            }
            Shutter(vm)
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
                SmallButton(Icons.Filled.FlipCameraAndroid, "FLIP") { vm.switchCamera() }
            }
        }
    }
}

@Composable
private fun TapeSlider(label: String, value: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.width(88.dp), color = Color.White, fontFamily = mono, fontWeight = FontWeight.Bold, fontSize = 11.sp)
        Slider(value, onChange, Modifier.weight(1f), valueRange = range)
        Text("${(value * 100).toInt()}", Modifier.width(34.dp), color = Color.White, fontFamily = mono, fontSize = 11.sp)
    }
}

@Composable
private fun SmallButton(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, onClick: () -> Unit) {
    Column(Modifier.width(52.dp).clickable(onClick = onClick).padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, tint = Color.White)
        Text(title, color = Color.White, fontFamily = mono, fontWeight = FontWeight.Bold, fontSize = 10.sp)
    }
}

@Composable
private fun Shutter(vm: CameraViewModel) {
    Box(Modifier.size(76.dp).border(4.dp, Color.White, CircleShape).clip(CircleShape)
        .clickable { if (vm.photoMode) vm.takePhoto() else vm.toggleRecording() },
        contentAlignment = Alignment.Center) {
        if (vm.photoMode) {
            Box(Modifier.size(58.dp).clip(CircleShape).background(Color.White))
        } else {
            val size = if (vm.recording) 30.dp else 56.dp
            val corner = if (vm.recording) 8.dp else 28.dp
            Box(Modifier.size(size).clip(RoundedCornerShape(corner)).background(Color.Red))
        }
    }
}
