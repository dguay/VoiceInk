package com.voiceink.keyboard.setup

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.CheckBox
import android.widget.ImageView
import android.widget.ListView
import android.widget.TextView
import com.voiceink.keyboard.R
import com.voiceink.keyboard.bubble.BubbleSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.Collator

/** Picks the installed apps the mic bubble never appears in. */
class BubbleExclusionsActivity : Activity() {
    private val scope = MainScope()
    private lateinit var settings: BubbleSettings
    private val apps = mutableListOf<InstalledApp>()
    private val adapter = AppAdapter()

    private class InstalledApp(val packageName: String, val label: String, val icon: Drawable)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_bubble_exclusions)
        applySystemBarInsets(findViewById(R.id.exclusions_root))
        settings = BubbleSettings(this)

        val list = findViewById<ListView>(R.id.exclusions_list)
        list.adapter = adapter
        list.setOnItemClickListener { _, _, position, _ ->
            val app = apps[position].packageName
            val excluded = settings.excludedApps
            settings.excludedApps = if (app in excluded) excluded - app else excluded + app
            adapter.notifyDataSetChanged()
        }

        scope.launch {
            val loaded = withContext(Dispatchers.IO) { launchableApps() }
            apps.addAll(loaded)
            adapter.notifyDataSetChanged()
            findViewById<View>(R.id.exclusions_loading).visibility = View.GONE
            list.visibility = View.VISIBLE
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /** Apps with a launcher icon, other than this one, alphabetically. */
    private fun launchableApps(): List<InstalledApp> {
        val pm = packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val collator = Collator.getInstance()
        return pm.queryIntentActivities(launcher, PackageManager.MATCH_ALL)
            .map { it.activityInfo.applicationInfo }
            .distinctBy { it.packageName }
            .filter { it.packageName != packageName }
            .map { InstalledApp(it.packageName, pm.getApplicationLabel(it).toString(), pm.getApplicationIcon(it)) }
            .sortedWith { a, b -> collator.compare(a.label, b.label) }
    }

    private inner class AppAdapter : BaseAdapter() {
        override fun getCount() = apps.size
        override fun getItem(position: Int) = apps[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = convertView ?: layoutInflater.inflate(R.layout.exclusion_row, parent, false)
            val app = apps[position]
            row.findViewById<ImageView>(R.id.app_icon).setImageDrawable(app.icon)
            row.findViewById<TextView>(R.id.app_label).text = app.label
            row.findViewById<CheckBox>(R.id.app_excluded).isChecked = app.packageName in settings.excludedApps
            return row
        }
    }
}
