package se.aicontrolcenter.lennart_app

import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Kopierar modellfilerna (flera hundra MB) från appens tillgångar till appens egen lagring vid
 * första start. Görs i Kotlin med strömmande läsning – att läsa in dem i Dart skulle kräva lika
 * mycket minne som filen är stor.
 */
class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lennart/assets").setMethodCallHandler { call, result ->
            when (call.method) {
                "extract" -> {
                    val asset = call.argument<String>("asset")!!
                    val dest = File(call.argument<String>("dest")!!)
                    worker.execute {
                        try {
                            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
                            val tmp = File(dest.path + ".tmp")
                            dest.parentFile?.mkdirs()
                            assets.open(key).use { input ->
                                tmp.outputStream().use { output -> input.copyTo(output, 1 shl 20) }
                            }
                            if (!tmp.renameTo(dest)) throw IllegalStateException("kunde inte byta namn på $tmp")
                            Handler(Looper.getMainLooper()).post { result.success(dest.length()) }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post { result.error("extract", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
