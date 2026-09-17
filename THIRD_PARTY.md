# 第三方资产与许可（THIRD_PARTY）

本仓库包含少量**第三方**字体与词典数据（以及由它们生成的运行时产物）。
它们各自保留原始许可，**不适用**本仓库的 MIT 许可（见 [LICENSE](LICENSE)）。
体积治理与再分发说明见下文；引入新第三方资产时请同步更新本文件
（独立验证者 issue #21）。

## 1. 字体

| 文件 | 体积 | 许可 | 来源 |
|---|---|---|---|
| `tools/m1/m1b/usr/share/fonts/wqy-zenhei.ttc` | 17,083,583 B | **GPL-2.0 + 字体嵌入例外**（WenQuanYi Zen Hei） | [WenQuanYi Zen Hei](http://wenq.org/wqy2/index.cgi?ZenHei)（Alpine `font-wqy-zenhei` 包内同名文件） |

用途：weston 键盘与终端的 CJK 字形（终端必须显式指定 `WenQuanYi Zen Hei Mono`，
cairo toy 字体不做逐字形回退）。GPL 的字体嵌入例外允许把字体嵌入/随附分发，
**不**要求整个项目按 GPL 授权；但字体文件本身仍是 GPL-2.0，再分发时须附带许可与来源。

## 2. 拼音/词典数据（构建输入，`tools/m1/ime/data/`）

这些文件只用于**离线生成** `pinyin.dict`，不进入设备镜像。

| 文件 | 体积 | 许可 | 来源（`fetch-data.sh`） |
|---|---|---|---|
| `pinyin.txt` | 985,318 B | **MIT** | `mozillazg/pinyin-data` |
| `kMandarin_8105.txt` | 168,058 B | **MIT** | 同上（通用规范汉字表） |
| `essay-zh-hans.txt` | 2,883,906 B | **LGPL-3.0** | `rime/rime-essay-simp` |
| `luna_pinyin.dict.yaml` | 889,896 B | **LGPL-3.0** | `rime/rime-luna-pinyin` |
| `cedict.zip` | 3,974,393 B | **CC BY-SA 4.0** | CC-CEDICT（经 mdbg 导出） |
| `cedict_ts.u8` | 9,847,992 B | **CC BY-SA 4.0** | 上者的解包结果 |

合计 ≈ 18.7 MB。

## 3. 运行时产物（提交入库）

| 文件 | 体积 | 许可/义务 | 生成方式 |
|---|---|---|---|
| `tools/m1/ime/pinyin.dict` | 221,036 B | **派生作品**：包含 CC BY-SA 4.0（CC-CEDICT）内容，故该文件按 **CC BY-SA 4.0** 分发；其余来源为 MIT / LGPL-3.0 | `tools/m1/ime/gen-dict.py`（`fetch-data.sh` 取源后离线生成） |

> **注意**：`pinyin.dict` 是唯一进入 rootfs 的词典产物（`tools/m1/m1b/usr/share/lmi/ime/`），
> 因此**再分发 `pinyin.dict` 时必须保留 CC BY-SA 4.0 署名与相同方式共享条款**。
> 若要把本项目整体重新许可，需先替换该词典的数据源。

## 4. 体积治理

- `tools/m1/ime/data/`（≈18.7 MB）是**构建输入**，可随时用 `fetch-data.sh` 重新拉取；
  如仓库体积是问题，可改为不提交（加进 `.gitignore`）——目前保留是为了**离线可复现**
  地重建 `pinyin.dict`（构建机不一定有网）。
- 字体（17 MB）与词典（221 KB）进的是设备 rootfs；`docs/installer-design.md`
  已把它们计入 1.5 GiB 槽位预算。
- 其余第三方依赖（weston 补丁、Alpine 包等）不随仓库分发，只在构建时从上游取得。

## 5. 相关

- IME 数据来源与选型：`docs/research/ux-ime-2026-09-15.md`、`tools/m1/ime/README.md`
- 凭据/隐私政策：`SECURITY.md`
