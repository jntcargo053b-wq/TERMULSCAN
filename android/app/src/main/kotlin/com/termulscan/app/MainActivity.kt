package com.termulscan.app

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.termulscan.app/location"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getLocation") {
                    getLocation(result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun getLocation(result: MethodChannel.Result) {
        try {
            if (ActivityCompat.checkSelfPermission(this,
                    Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
                ActivityCompat.checkSelfPermission(this,
                    Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                result.success(null)
                return
            }

            val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val handler = Handler(Looper.getMainLooper())
            var responded = false

            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    if (!responded) {
                        responded = true
                        locationManager.removeUpdates(this)
                        result.success(mapOf(
                            "lat" to location.latitude,
                            "lng" to location.longitude,
                            "accuracy" to location.accuracy,
                            "address" to null
                        ))
                    }
                }
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }

            // Timeout 10 detik — kalau GPS tidak dapat sinyal, pakai lastKnown atau null
            handler.postDelayed({
                if (!responded) {
                    responded = true
                    locationManager.removeUpdates(listener)

                    // Fallback ke lastKnownLocation
                    var fallback: Location? = null
                    if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                        fallback = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                    }
                    if (fallback == null && locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                        fallback = locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                    }

                    if (fallback != null) {
                        result.success(mapOf(
                            "lat" to fallback.latitude,
                            "lng" to fallback.longitude,
                            "accuracy" to fallback.accuracy,
                            "address" to null
                        ))
                    } else {
                        result.success(null)
                    }
                }
            }, 10000)

            // Request update dari GPS dan Network
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER
            )
            var requested = false
            for (provider in providers) {
                if (locationManager.isProviderEnabled(provider)) {
                    locationManager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                    requested = true
                    break
                }
            }

            // Tidak ada provider aktif
            if (!requested) {
                responded = true
                result.success(null)
            }

        } catch (e: Exception) {
            result.success(null)
        }
    }
}
