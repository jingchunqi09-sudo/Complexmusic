// 小提琴琴弓传感器模块：参数化草模
// 状态：concept_only。所有未标“资料确定”的数值都要用实物复测后冻结。
$fn = 48;

BOW_STICK_DIAMETER = 10.0;   // 初始占位，mm
CLAMP_BORE = 10.6;           // 初始占位，mm
CLAMP_X = 30.0;
CLAMP_Y = 18.0;
CLAMP_Z = 18.0;
POD_X = 28.0;
POD_Y = 18.0;
POD_Z = 10.0;
POD_Y_OFFSET = 15.0;
PCB_T = 1.60;                // 项目PMW3360指南首版参考
WINDOW_X = 6.0;
WINDOW_Y = 4.0;
WORKING_Z = 2.4;             // 资料确定范围为2.2–2.6；此处取中值示意
RAIL_X = 80.0;
RAIL_Y = 12.0;
RAIL_Z = 3.0;

module rounded_box(size=[10,10,10], r=1.5) {
    // 仅用于概念外壳；尺寸以外包络为准
    minkowski() {
        cube([size[0]-2*r, size[1]-2*r, size[2]-2*r], center=true);
        sphere(r=r);
    }
}

module bow_stick() {
    color("#6d4930")
        rotate([0,90,0]) cylinder(d=BOW_STICK_DIAMETER, h=70, center=true);
}

module split_clamp() {
    // 夹壳采用上下分体概念；实际弓杆可能是八边形，需改为实测截面
    difference() {
        color("#30343a") rounded_box([CLAMP_X, CLAMP_Y, CLAMP_Z], 1.5);
        rotate([0,90,0]) cylinder(d=CLAMP_BORE, h=CLAMP_X+2, center=true);
        // 中央分割缝
        translate([0,0,0]) cube([CLAMP_X+2, 0.8, CLAMP_Z+2], center=true);
    }
}

module sensor_pod() {
    // pod位于弓杆一侧，窗口朝下(-Z)
    translate([0, POD_Y_OFFSET, CLAMP_Z/2 + POD_Z/2 - 1]) {
        difference() {
            color("#25292e") rounded_box([POD_X, POD_Y, POD_Z], 1.5);
            translate([0,0,-POD_Z/2-0.1])
                color("#111111") cube([WINDOW_X, WINDOW_Y, 0.8], center=true);
        }
        // PCB与镜头座示意，不代表最终封装
        translate([0,0,-1.0]) color("#1d6b4f") cube([POD_X-4, POD_Y-4, PCB_T], center=true);
        translate([0,0,-POD_Z/2+0.7]) color("#d6b36a") cube([WINDOW_X+2, WINDOW_Y+2, 1.0], center=true);
    }
}

module clamp_screws() {
    for (x=[-10,10])
        translate([x,0,0]) rotate([90,0,0]) {
            color("#b8bec5") cylinder(d=2.6, h=24, center=true);
            translate([0,12,0]) color("#b8bec5") cylinder(d=5.0, h=2.5, center=true);
        }
}

module textured_reference_rail() {
    // 独立固定的纹理参考条，不属于弓；仅用于表达光学工作距离
    translate([0,POD_Y_OFFSET,-CLAMP_Z/2-WORKING_Z-RAIL_Z/2]) {
        color("#8b8f95") cube([RAIL_X, RAIL_Y, RAIL_Z], center=true);
        for (x=[-35:5:35])
            translate([x,0,RAIL_Z/2+0.05]) color("#5e6369") cube([1.0,RAIL_Y,0.15], center=true);
    }
}

module bow_sensor_module() {
    bow_stick();
    split_clamp();
    sensor_pod();
    clamp_screws();
    textured_reference_rail();
}

bow_sensor_module();
