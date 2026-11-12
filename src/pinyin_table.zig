//! 由 `tools/gen_pinyin.py` 生成，请勿手改。
//!
//! 源：C# `DH.NCore/DH.NCore/Common/PinYin.cs` 的 `pyName` + `_pyValue2` + `_pyValue3`。
//! 改拼音表请改 C# 源后重新生成，不要在 Zig 侧手改。

/// 拼音名（下标与 `pinyin_table.bin` 里的值对应）
pub const names = [_][]const u8{
    "A", "Ai", "An", "Ang", "Ao", "Ba", "Bai", "Ban",
    "Bang", "Bao", "Bei", "Ben", "Beng", "Bi", "Bian", "Biao",
    "Bie", "Bin", "Bing", "Bo", "Bu", "Ba", "Cai", "Can",
    "Cang", "Cao", "Ce", "Ceng", "Cha", "Chai", "Chan", "Chang",
    "Chao", "Che", "Chen", "Cheng", "Chi", "Chong", "Chou", "Chu",
    "Chuai", "Chuan", "Chuang", "Chui", "Chun", "Chuo", "Ci", "Cong",
    "Cou", "Cu", "Cuan", "Cui", "Cun", "Cuo", "Da", "Dai",
    "Dan", "Dang", "Dao", "De", "Deng", "Di", "Dian", "Diao",
    "Die", "Ding", "Diu", "Dong", "Dou", "Du", "Duan", "Dui",
    "Dun", "Duo", "E", "En", "Er", "Fa", "Fan", "Fang",
    "Fei", "Fen", "Feng", "Fo", "Fou", "Fu", "Ga", "Gai",
    "Gan", "Gang", "Gao", "Ge", "Gei", "Gen", "Geng", "Gong",
    "Gou", "Gu", "Gua", "Guai", "Guan", "Guang", "Gui", "Gun",
    "Guo", "Ha", "Hai", "Han", "Hang", "Hao", "He", "Hei",
    "Hen", "Heng", "Hong", "Hou", "Hu", "Hua", "Huai", "Huan",
    "Huang", "Hui", "Hun", "Huo", "Ji", "Jia", "Jian", "Jiang",
    "Jiao", "Jie", "Jin", "Jing", "Jiong", "Jiu", "Ju", "Juan",
    "Jue", "Jun", "Ka", "Kai", "Kan", "Kang", "Kao", "Ke",
    "Ken", "Keng", "Kong", "Kou", "Ku", "Kua", "Kuai", "Kuan",
    "Kuang", "Kui", "Kun", "Kuo", "La", "Lai", "Lan", "Lang",
    "Lao", "Le", "Lei", "Leng", "Li", "Lia", "Lian", "Liang",
    "Liao", "Lie", "Lin", "Ling", "Liu", "Long", "Lou", "Lu",
    "Lv", "Luan", "Lue", "Lun", "Luo", "Ma", "Mai", "Man",
    "Mang", "Mao", "Me", "Mei", "Men", "Meng", "Mi", "Mian",
    "Miao", "Mie", "Min", "Ming", "Miu", "Mo", "Mou", "Mu",
    "Na", "Nai", "Nan", "Nang", "Nao", "Ne", "Nei", "Nen",
    "Neng", "Ni", "Nian", "Niang", "Niao", "Nie", "Nin", "Ning",
    "Niu", "Nong", "Nu", "Nv", "Nuan", "Nue", "Nuo", "O",
    "Ou", "Pa", "Pai", "Pan", "Pang", "Pao", "Pei", "Pen",
    "Peng", "Pi", "Pian", "Piao", "Pie", "Pin", "Ping", "Po",
    "Pu", "Qi", "Qia", "Qian", "Qiang", "Qiao", "Qie", "Qin",
    "Qing", "Qiong", "Qiu", "Qu", "Quan", "Que", "Qun", "Ran",
    "Rang", "Rao", "Re", "Ren", "Reng", "Ri", "Rong", "Rou",
    "Ru", "Ruan", "Rui", "Run", "Ruo", "Sa", "Sai", "San",
    "Sang", "Sao", "Se", "Sen", "Seng", "Sha", "Shai", "Shan",
    "Shang", "Shao", "She", "Shen", "Sheng", "Shi", "Shou", "Shu",
    "Shua", "Shuai", "Shuan", "Shuang", "Shui", "Shun", "Shuo", "Si",
    "Song", "Sou", "Su", "Suan", "Sui", "Sun", "Suo", "Ta",
    "Tai", "Tan", "Tang", "Tao", "Te", "Teng", "Ti", "Tian",
    "Tiao", "Tie", "Ting", "Tong", "Tou", "Tu", "Tuan", "Tui",
    "Tun", "Tuo", "Wa", "Wai", "Wan", "Wang", "Wei", "Wen",
    "Weng", "Wo", "Wu", "Xi", "Xia", "Xian", "Xiang", "Xiao",
    "Xie", "Xin", "Xing", "Xiong", "Xiu", "Xu", "Xuan", "Xue",
    "Xun", "Ya", "Yan", "Yang", "Yao", "Ye", "Yi", "Yin",
    "Ying", "Yo", "Yong", "You", "Yu", "Yuan", "Yue", "Yun",
    "Za", "Zai", "Zan", "Zang", "Zao", "Ze", "Zei", "Zen",
    "Zeng", "Zha", "Zhai", "Zhan", "Zhang", "Zhao", "Zhe", "Zhen",
    "Zheng", "Zhi", "Zhong", "Zhou", "Zhu", "Zhua", "Zhuai", "Zhuan",
    "Zhuang", "Zhui", "Zhun", "Zhuo", "Zi", "Zong", "Zou", "Zu",
    "Zuan", "Zui", "Zun", "Zuo", "Dia", "Cen", "Pou", "Ca",
    "Nou", "Ei", "Lve",
};

/// 码表覆盖的 Unicode 区间起点（含）
pub const first_code: u32 = 0x4E00;
/// 码表覆盖的 Unicode 区间终点（含）
pub const last_code: u32 = 0x9FA5;

test "码表长度与区间一致" {
    const bin = @embedFile("pinyin_table.bin");
    try @import("std").testing.expectEqual((last_code - first_code + 1) * 2, bin.len);
}
