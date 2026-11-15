package com.josebamuro.director_de_rol

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Modelos de voz incluidos en el APK (assets/incluidos). Se copian a
        // disco por trozos porque sherpa-onnx necesita rutas de fichero.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "director_de_rol/incluidos")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readText" -> {
                        val path = call.argument<String>("path")!!
                        try {
                            val text = assets.open(path).use { it.readBytes().toString(Charsets.UTF_8) }
                            result.success(text)
                        } catch (e: FileNotFoundException) {
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("leer", e.message, null)
                        }
                    }
                    "copy" -> {
                        val path = call.argument<String>("path")!!
                        val dest = File(call.argument<String>("dest")!!)
                        thread(name = "copiar-incluidos") {
                            try {
                                dest.parentFile?.mkdirs()
                                val part = File(dest.path + ".part")
                                assets.open(path).use { input ->
                                    part.outputStream().use { output -> input.copyTo(output, 1 shl 20) }
                                }
                                if (dest.exists()) dest.delete()
                                if (!part.renameTo(dest)) throw Exception("no se pudo renombrar ${part.name}")
                                runOnUiThread { result.success(null) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("copiar", e.message, null) }
                            }
                        }
                    }
                    // Carpeta de las bibliotecas nativas: ahí va el generador de
                    // imágenes (libsdcli.so), el único sitio desde el que Android
                    // deja ejecutar un programa incluido en el APK.
                    "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                    else -> result.notImplemented()
                }
            }
    }
}
