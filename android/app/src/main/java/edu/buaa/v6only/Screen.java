package edu.buaa.v6only;

import android.app.Activity;
import android.view.View;
import android.widget.*;

/** Shared native controls, responsive content width and system-bar insets. */
final class Screen {
    static int dp(Activity a, int n) { return Math.round(n*a.getResources().getDisplayMetrics().density); }
    static LinearLayout page(Activity a, String title) {
        ScrollView scroll = new ScrollView(a);
        scroll.setBackgroundColor(a.getColor(R.color.page));
        scroll.setFillViewport(true);
        LinearLayout content = new LinearLayout(a);
        content.setOrientation(LinearLayout.VERTICAL);
        int p=dp(a,20); content.setPadding(p,p,p,dp(a,28));
        ScrollView.LayoutParams layout = new ScrollView.LayoutParams(-1,-2);
        layout.gravity=android.view.Gravity.CENTER_HORIZONTAL;
        scroll.addView(content,layout);
        a.setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener((v,insets)->{
            android.graphics.Insets bars=insets.getSystemWindowInsets();
            v.setPadding(bars.left,bars.top,bars.right,bars.bottom); return insets;
        });
        scroll.addOnLayoutChangeListener((v,l,t,r,b,ol,ot,or,ob)->{
            int w=Math.min(r-l,dp(a,600));
            if(w>0 && content.getLayoutParams().width!=w) { content.getLayoutParams().width=w; content.requestLayout(); }
        });
        Button back=button(a,content,"返回"); back.setOnClickListener(v->a.finish());
        TextView heading=text(a,content,title,26); heading.setAccessibilityHeading(true);
        return content;
    }
    static TextView text(Activity a, LinearLayout parent, String value, int size) {
        TextView t=new TextView(a); t.setText(value); t.setTextSize(size);
        t.setTextColor(a.getColor(R.color.ink));
        t.setPadding(0,dp(a,8),0,dp(a,8));
        parent.addView(t,new LinearLayout.LayoutParams(-1,-2)); return t;
    }
    static Button button(Activity a, LinearLayout parent, String value) {
        Button b=new Button(a); b.setText(value); b.setAllCaps(false); b.setMinHeight(dp(a,48));
        parent.addView(b,new LinearLayout.LayoutParams(-1,-2)); return b;
    }
}
