# 固件清单（P0 交付物）— 2026-09-17

> `docs/peripheral-bringup-plan.md` **P0（固件侦察）**的交付物。
> **专有固件不入仓**：本文件只记录**来源、目标路径、大小、sha256 与许可**；
> 固件本体保存在本机暂存目录与设备 rootfs 的 `/lib/firmware/`（`SECURITY.md` §凭据与隐私）。
> 记录方式沿用 WiFi 凭据的既有做法：本地注入 + 入库只放"可复现的提取脚本与校验值"。

## 1. 结论（2026-09-17 实测）

- **ADSP/音频固件就在本机上**，不需要下载原厂 MIUI 包，也不需要公开 `linux-firmware`：
  它在 `/vendor/firmware_mnt/image/`（Android 侧挂载：`/dev/block/sde51`，vfat，`firmware_mnt`）。
  这是**与本机 ADSP 版本完全匹配**的分段格式（`adsp.mdt` + `adsp.b00`…`adsp.b18`）。
- 内核**请求的文件名是 `adsp.mdt`**：DT `17300000.qcom,lpass` 的 `qcom,firmware-name = "adsp"`
  （`pil-q6v5.c: pil_q6v5_init()` 读取），`subsys-pil-tz` 经 `request_firmware()` 到
  **`/lib/firmware/adsp.mdt`**（分段文件同目录，同名 + `.bNN`）。
- **蓝牙固件也在本机上**（`/vendor/bt_firmware`，`/dev/block/sde35`，`bluetooth` 分区）——
  这**修正**了 `docs/bluetooth-assessment.md` §1 里"Android 侧没有 QCA6390 BT 固件"的说法
  （当时 `/vendor/bt_firmware` 未挂载/为空）。BT 结论不变（见 §4）。

## 2. ADSP（音频）— 22 个文件，20,356,050 B

来源：设备 Android 侧 `/vendor/firmware_mnt/image/`（原厂 MIUI 随 OTA 的
`firmware_mnt` 镜像）。提取脚本：`tools/p3/extract-adsp-firmware.sh`（adb，只读）。

| 文件 | 字节 | sha256 |
|---|---|---|
| `adsp.mdt` | 8220 | `830a0f4fb7b11051b0e02ca66f4bd92128c4647a11ce02cdbd3e9e2db159d124` |
| `adsp.b00` | 692 | `fc38a882a23d3ae78976299a88f76e828a2a0e2851dbc9327c1cfe22d2119a4c` |
| `adsp.b01` | 7528 | `a2477376511fe986476dae7afb5378512f4155026bd40e559fff4b369b9cec12` |
| `adsp.b02` | 82424 | `44ae69d50b8cf1fdfd643b299dd80c7a63ce64b76366d8bac9f0ac73213febfe` |
| `adsp.b03` | 358784 | `b4659e26eaae5d41eb6559410d88e758bb9fc9b598234fd4c55a849168b9aa45` |
| `adsp.b04` | 1947868 | `69a0d88397c1fefefe72998f55d9ca27edcdb729bc071ebd2a4849e9da1232e2` |
| `adsp.b05` | 2487860 | `1a24e81181138f1830eb4c406d64c29fad7c2e15e4b12462fd8325c004dd52a7` |
| `adsp.b06` | 38640 | `6330322efc9e7ceb48f9c2c75db0e38f6f546f04f11a96b2da4695ad0ca8277b` |
| `adsp.b07` | 28972 | `a6a8d8806e1aa4c55eb1b0a27bca2970a1c065384d89e7f8ad2062e335ed2eac` |
| `adsp.b08` | 126736 | `a86bae6370d990950ea4b5f59cc63d88756dabf8cf9714e8287484bd081e66ce` |
| `adsp.b09` | 64360 | `9ac7cfd298486be684abd4277d42857ec6a9b07f34c48616b8d819df1d7828de` |
| `adsp.b10` | 98304 | `3a3ed164e42500a1c5b2d0093f0a813d27dc50d038f330cc100a7e70ece2e6e4` |
| `adsp.b11` | 11228364 | `069eed69f5a263fc341ea40c3789dbf4d189bf508790bcb8934d954761c32725` |
| `adsp.b12` | 685000 | `c8cf40764939100ee21d69f8b7f91bbce80811fa3072fe1a3e7d208d36e89a2e` |
| `adsp.b13` | 3544 | `c936a7e0c6304ac229c04f18eaab727c7ff9f734b0aa23512c72d2d5b228ca3a` |
| `adsp.b14` | 270292 | `ae4f77d1af002d23d567bfbf1b959a6512b26c782970e37840d1713f605c31c9` |
| `adsp.b15` | 1112980 | `db6059663511600fa2542c38546bb261019b6869879e54d9102979c79bb08b0f` |
| `adsp.b16` | 106544 | `a18b3446a4bb1901ec0a81df890f8c165275f869db7ab5ad1a747344895efa88` |
| `adsp.b17` | 1697856 | `f1c441de591e5d9d4dc045f6f1a2d90da15f8433c6ad295023ccf4d688bd31ec` |
| `adsp.b18` | 124 | `34d4c09a35a4aca82be8d2f23fc38d7c03b8e963da510e29a3cbb22fa49d76d4` |
| `adspr.jsn` | 403 | `4781dc9312fa017b0e611c752dae2183c0f205af8300b28417a496dae511b0a5` |
| `adspua.jsn` | 555 | `d6c6376f53e5449eb4f7b9e5a30679ebc2a9afaad28c13ff171f979e7b1af1f6` |

部署位置：**`/lib/firmware/`**（rootfs 内，持久）。`tools/p3/install-adsp-firmware.sh`
负责推送并逐文件校验。

### 2.1 `adspr.jsn` / `adspua.jsn` 是**保护域（PD）地图**，不是固件分段

两者是 Qualcomm "service registry" JSON（`sr_version` / `sr_domain` / `sr_service`），
`adspua.jsn` 就是**音频 PD 的地图**：

```json
"sr_domain":  { "soc": "msm", "domain": "adsp", "subdomain": "audio_pd",
                "qmi_instance_id": 74 },
"sr_service": [ { "provider": "tms", "service": "servreg" },
                { "provider": "avs", "service": "audio"  } ]
```

与实机 QRTR 广告完全吻合：ADSP（node 5）上
`service 0x42 / version 1 / instance 74 / port 3 = "Service registry notification service"`。
**这是下一个 blocker（apps 侧 servreg locator）的关键输入** —— 详见
`docs/bluetooth-assessment.md` §6c。

## 3. 其它已取到的固件（存档，未部署）

| 组 | 文件 | 字节 | 位置（Android） |
|---|---|---|---|
| CDSP | `cdsp.mdt` + `cdsp.b00…b11` + `cdspr.jsn` | — | `/vendor/firmware_mnt/image/` |
| SLPI（传感器 DSP） | `slpi.mdt` + `slpi.b00…b20` + `slpir.jsn`/`slpius.jsn` | — | 同上 |
| Venus（视频） | `venus.mdt` + `venus.b*` | — | 同上 |
| **蓝牙 QCA6390** | `htbtfw10.tlv`(129,964) `htbtfw20.tlv`(188,564) `htnv10.bin`(3,569) `htnv20.bin`(5,733) | — | `/vendor/bt_firmware/image/`（`/dev/block/sde35`） |

> 只有 ADSP 是本期（P3 音频）需要的。CDSP/SLPI/Venus 与蓝牙固件**不入镜像、不部署**；
> 蓝牙即使有固件也不可行（`docs/bluetooth-assessment.md` §6b）。

## 4. 许可与分发

- ADSP/CDSP/SLPI/Venus 与 QCA6390 BT 固件均为**高通专有**（随设备/原厂包分发，
  未授予再分发许可）。因此：
  - **仓库、发布物、通用镜像一律不含固件**（M5 安装器只装 rootfs，见 `docs/installer-design.md`）；
  - 提取/部署只走本地脚本（`tools/p3/`），固件本体放
    `%TEMP%\opencode\p3\fw\`（本机）与设备 `/lib/firmware/`；
  - 本文件只记录 sha256，供复验。
- 公开 `linux-firmware` 里有 `qcom/sm8250/adsp.mbn`（单文件格式），但**本下游内核
  `msm_pil`/`subsys-pil-tz` 要的是分段 `adsp.mdt` + `adsp.b*`**，且设备自带那份
  版本严格匹配 → 不采用公开仓库那套。

## 5. 复现

```sh
# PC（Android 在线；只读抽取到本地暂存目录并打印 sha256）
tools/p3/extract-adsp-firmware.sh --out "$TEMP/opencode/p3/fw"

# 设备（Linux 侧 root）：推送 + 校验 + 尝试起 ADSP
tools/p3/install-adsp-firmware.sh --from /root/p3fw     # 或直接 scp 后 --from <dir>
```
