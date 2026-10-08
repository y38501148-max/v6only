package edu.buaa.v6only;
import java.util.Locale;
/** Manufacturer aliases and ordered, optional OEM settings entry points. */
final class BackgroundPolicy {
    static String brand(String manufacturer, String brand) {
        String s=(manufacturer+" "+brand).toLowerCase(Locale.ROOT);
        if(s.contains("iqoo")) return "iQOO";
        if(s.contains("vivo")) return "vivo";
        if(s.contains("xiaomi")||s.contains("redmi")||s.contains("poco")) return "小米 / Redmi / POCO";
        if(s.contains("honor")) return "荣耀";
        if(s.contains("huawei")) return "华为";
        if(s.contains("oneplus")) return "一加";
        if(s.contains("realme")) return "realme";
        if(s.contains("oppo")) return "OPPO";
        if(s.contains("samsung")) return "三星";
        return "Android";
    }
    static String[] components(String b) {
        if(b.startsWith("小米")) return new String[]{"com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity"};
        if(b.equals("华为")||b.equals("荣耀")) return new String[]{"com.huawei.systemmanager/com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity","com.hihonor.systemmanager/com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"};
        if(b.equals("vivo")||b.equals("iQOO")) return new String[]{"com.vivo.permissionmanager/com.vivo.permissionmanager.activity.BgStartUpManagerActivity","com.iqoo.secure/com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"};
        if(b.equals("OPPO")||b.equals("realme")||b.equals("一加")) return new String[]{"com.oplus.safecenter/com.oplus.safecenter.startupapp.StartupAppListActivity","com.coloros.safecenter/com.coloros.safecenter.permission.startup.StartupAppListActivity","com.coloros.safecenter/com.coloros.safecenter.startupapp.StartupAppListActivity"};
        if(b.equals("三星")) return new String[]{"com.samsung.android.lool/com.samsung.android.sm.ui.battery.BatteryActivity","com.samsung.android.sm/com.samsung.android.sm.ui.battery.BatteryActivity"};
        return new String[0];
    }
    static String guidance(String b) {
        if(b.equals("华为")||b.equals("荣耀")) return "在应用启动管理中关闭自动管理，允许自启动、关联启动和后台活动。";
        if(b.startsWith("小米")) return "允许自启动，将省电策略设为无限制。";
        if(b.equals("iQOO")||b.equals("vivo")) return "允许自启动，将后台耗电管理设为允许后台高耗电。";
        if(b.equals("三星")) return "将 V6Only 加入从不休眠的应用。";
        if(b.equals("OPPO")||b.equals("一加")||b.equals("realme")) return "允许自启动和后台活动，关闭应用的耗电限制。";
        return "允许自启动和后台活动，将电池使用设为不受限制。";
    }
}
