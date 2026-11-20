package se.aicontrolcenter.lennart_app

import android.app.Activity
import android.content.Intent
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
    private var pickResult: MethodChannel.Result? = null
    private val pickRequest = 4711

    private fun post(block: () -> Unit) = Handler(Looper.getMainLooper()).post(block)

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
                "pickFile" -> {
                    // Telefonens filväljare; den valda filen kopieras till appens cache.
                    pickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    startActivityForResult(intent, pickRequest)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Används för filväljaren")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequest) return
        val result = pickResult ?: return
        pickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        worker.execute {
            try {
                val dest = File(cacheDir, "import.lennart")
                contentResolver.openInputStream(uri)!!.use { input ->
                    dest.outputStream().use { output -> input.copyTo(output, 1 shl 20) }
                }
                post { result.success(dest.path) }
            } catch (e: Exception) {
                post { result.error("pickFile", e.message, null) }
            }
        }
    }
}
