// Test-only reference from the pre-optimization rain renderer. Not an app resource.
float4 referenceRainWidgetImpact(RainDrop drop, constant Uniforms &u, constant WidgetRainLayout &layout) {
    float wind = u.weather.w*u.celestial.w;
    float firstY = 2, firstX = 0;
    for (uint i = 0; i < uint(layout.settings.x); ++i) {
        float4 rect = layout.areas[i].rect;
        float radius = min(layout.areas[i].options.x,min(rect.z*u.viewport.w,rect.w)*0.5);
        float y = rect.y, x = 0;
        for (uint iteration = 0; iteration < 3; ++iteration) {
            float age = (drop.center.y+drop.size.y*0.7-y)/drop.speed;
            x = fract(drop.seed+windPhase(0.018,u)-wind*1.35*0.018*age+y*wind*0.055
                +sin(drop.phase-0.8*age)*0.002)*1.2-0.1;
            float dx = max(0.0,max(rect.x+radius/u.viewport.w-x,x-(rect.x+rect.z-radius/u.viewport.w)))*u.viewport.w;
            y = rect.y+radius-sqrt(max(0.0,radius*radius-dx*dx));
        }
        if (x >= rect.x && x <= rect.x+rect.z && y < firstY) { firstY = y; firstX = x; }
    }
    return float4(firstX,firstY,(drop.center.y+drop.size.y*0.7-firstY)/drop.speed,firstY < 2 ? 1 : 0);
}
