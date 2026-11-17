# MediaTek MT6833 DVFS & Voltage Table Reference

## 1. Voltage Step Formula (MT6359 PMIC)
The MT6359 PMIC uses linear voltage encoding:
$$\text{Voltage (mV)} = \text{Step} \times 6.25 + 400.0$$
$$\text{Voltage (uV)} = (\text{Step} \times 6.25 + 400.0) \times 1000$$

* Step `0` = $400.00\text{ mV}$
* Step `24` (`0x18`) = $550.00\text{ mV}$ (Hardware PMIC floor)
* Step `29` (`0x1d`) = $581.25\text{ mV}$ (v1.8 minimum underclock voltage)
* Step `88` (`0x58`) = $950.00\text{ mV}$ (v1.8 Little OPP 0)
* Step `96` (`0x60`) = $1000.00\text{ mV}$ (v1.8 Big OPP 0)

---

## 2. CPU OPP Tables (v1.8 Profile: -50.00 mV CPU & Cache SRAM)

### Little Cluster (6x Cortex-A55)
* Stock Range: 500 MHz (550.00 mV eFuse / 650.00 mV nominal) – 2000 MHz (812.50 mV eFuse / 1000.00 mV nominal)
* Patched Range: **200 MHz (581.25 mV) – 2000 MHz (950.00 mV)**

| OPP Index | Frequency | Stock Nominal | Stock eFuse | Patched Nominal | Delta vs Stock | PLL Config (a, b) | VCO Freq |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 2000 MHz | 1000.00 mV | 812.50 mV | **950.00 mV** | -50.00 mV | (1, 1) | 2000 MHz |
| 1 | 1916 MHz |  975.00 mV | 787.50 mV | **925.00 mV** | -50.00 mV | (1, 1) | 1916 MHz |
| 2 | 1812 MHz |  943.75 mV | 750.00 mV | **893.75 mV** | -50.00 mV | (1, 1) | 1812 MHz |
| 3 | 1750 MHz |  925.00 mV | 731.25 mV | **875.00 mV** | -50.00 mV | (1, 1) | 1750 MHz |
| 4 | 1645 MHz |  893.75 mV | 693.75 mV | **843.75 mV** | -50.00 mV | (2, 1) | 3290 MHz |
| 5 | 1500 MHz |  850.00 mV | 643.75 mV | **800.00 mV** | -50.00 mV | (2, 1) | 3000 MHz |
| 6 | 1393 MHz |  825.00 mV | 637.50 mV | **775.00 mV** | -50.00 mV | (2, 1) | 2786 MHz |
| 7 | 1287 MHz |  800.00 mV | 625.00 mV | **750.00 mV** | -50.00 mV | (2, 1) | 2574 MHz |
| 8 | 1128 MHz |  762.50 mV | 606.25 mV | **712.50 mV** | -50.00 mV | (2, 1) | 2256 MHz |
| 9 | 1048 MHz |  743.75 mV | 600.00 mV | **693.75 mV** | -50.00 mV | (2, 1) | 2096 MHz |
| 10 |  968 MHz |  725.00 mV | 587.50 mV | **675.00 mV** | -50.00 mV | (2, 1) | 1936 MHz |
| 11 |  862 MHz |  700.00 mV | 581.25 mV | **662.50 mV** | -37.50 mV | (2, 1) | 1724 MHz |
| 12 |  756 MHz |  675.00 mV | 568.75 mV | **637.50 mV** | -37.50 mV | (4, 1) | 3024 MHz |
| 13 |  703 MHz |  662.50 mV | 562.50 mV | **625.00 mV** | -37.50 mV | (4, 1) | 2812 MHz |
| 14 |  500 MHz |  650.00 mV | 550.00 mV | **593.75 mV** | -56.25 mV | (4, 1) | 2000 MHz |
| 15 | **200 MHz** | *(unlocked)* | *(unlocked)* | **581.25 mV** | **Underclock** | (4, 2) | 1600 MHz |

---

### Big Cluster (2x Cortex-A76)
* Stock Range: 725 MHz (550.00 mV eFuse / 650.00 mV nominal) – 2400 MHz (781.25 mV eFuse / 1050.00 mV nominal)
* Patched Range: **200 MHz (581.25 mV) – 2400 MHz (1000.00 mV)**

| OPP Index | Frequency | Stock Nominal | Stock eFuse | Patched Nominal | Delta vs Stock | PLL Config (a, b) | VCO Freq |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 2400 MHz | 1050.00 mV | 781.25 mV | **1000.00 mV** | -50.00 mV | (1, 1) | 2400 MHz |
| 1 | 2306 MHz | 1031.25 mV | 762.50 mV | **981.25 mV** | -50.00 mV | (1, 1) | 2306 MHz |
| 2 | 2203 MHz | 1012.50 mV | 743.75 mV | **962.50 mV** | -50.00 mV | (1, 1) | 2203 MHz |
| 3 | 2118 MHz |  993.75 mV | 725.00 mV | **943.75 mV** | -50.00 mV | (1, 1) | 2118 MHz |
| 4 | 1993 MHz |  968.75 mV | 700.00 mV | **918.75 mV** | -50.00 mV | (1, 1) | 1993 MHz |
| 5 | 1837 MHz |  937.50 mV | 668.75 mV | **887.50 mV** | -50.00 mV | (1, 1) | 1837 MHz |
| 6 | 1650 MHz |  900.00 mV | 631.25 mV | **850.00 mV** | -50.00 mV | (2, 1) | 3300 MHz |
| 7 | 1534 MHz |  868.75 mV | 625.00 mV | **818.75 mV** | -50.00 mV | (2, 1) | 3068 MHz |
| 8 | 1418 MHz |  837.50 mV | 612.50 mV | **787.50 mV** | -50.00 mV | (2, 1) | 2836 MHz |
| 9 | 1274 MHz |  800.00 mV | 600.00 mV | **750.00 mV** | -50.00 mV | (2, 1) | 2548 MHz |
| 10 | 1129 MHz |  756.25 mV | 587.50 mV | **706.25 mV** | -50.00 mV | (2, 1) | 2258 MHz |
| 11 | 1042 MHz |  737.50 mV | 581.25 mV | **687.50 mV** | -50.00 mV | (2, 1) | 2084 MHz |
| 12 |  985 MHz |  718.75 mV | 575.00 mV | **681.25 mV** | -37.50 mV | (2, 1) | 1970 MHz |
| 13 |  898 MHz |  693.75 mV | 568.75 mV | **656.25 mV** | -37.50 mV | (2, 1) | 1796 MHz |
| 14 |  500 MHz |  681.25 mV | 562.50 mV | **593.75 mV** | -87.50 mV | (4, 1) | 2000 MHz |
| 15 | **200 MHz** | *(unlocked)* | 550.00 mV | **581.25 mV** | **Underclock** | (4, 2) | 1600 MHz |

---

### CPU Cache SRAM Dynamic Tracking (vsram_proc1 / vsram_proc2)
The MT6833 MCUPM coprocessor dynamically tracks CPU logic voltage ($V_{\text{proc}}$) using the hardware rule:
$$V_{\text{sram}} = \max\left(750.00\text{ mV},\; V_{\text{proc}} + 100.00\text{ mV}\right)$$

* At full 2.4 GHz Big load: $V_{\text{proc2}} = 812.50\text{ mV} \implies V_{\text{sram2}} = 912.50\text{ mV}$.
* At idle / low frequency ($\le 1400\text{ MHz}$): $V_{\text{sram}}$ clamps cleanly to the **750.00 mV** hardware floor to protect 6T SRAM bitcell retention ($V_{\text{min}}$).

---

## 3. GPU OPP Table (Mali-G57 MC2, -50.00 mV Profile)
The GPU table consists of 45 operating points inside `g_default_gpu` in `mtk_gpufreq_mt6833.ko`.

* **Hardware Limit**: $\Delta(V_{\text{sram}} - V_{\text{gpu}}) \le 200.00\text{ mV}$ (Strictly enforced by hardware).

| OPP Index | Frequency | Stock Vgpu | Patched Vgpu | Stock Vsram | Patched Vsram | Delta (Vsram-Vgpu) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 (Max) | 1068 MHz | 850.00 mV | **800.00 mV** | 850.00 mV | **800.00 mV** | 0.00 mV |
| 1 | 1059 MHz | 843.75 mV | **793.75 mV** | 843.75 mV | **793.75 mV** | 0.00 mV |
| 5 | 1025 MHz | 818.75 mV | **768.75 mV** | 818.75 mV | **768.75 mV** | 0.00 mV |
| 10 | 970 MHz | 787.50 mV | **737.50 mV** | 787.50 mV | **750.00 mV** | 12.50 mV |
| 15 | 895 MHz | 756.25 mV | **706.25 mV** | 750.00 mV | **750.00 mV** | 43.75 mV |
| 20 | 835 MHz | 725.00 mV | **675.00 mV** | 750.00 mV | **750.00 mV** | 75.00 mV |
| 25 | 778 MHz | 693.75 mV | **643.75 mV** | 750.00 mV | **750.00 mV** | 106.25 mV |
| 30 | 722 MHz | 662.50 mV | **612.50 mV** | 750.00 mV | **750.00 mV** | 137.50 mV |
| 35 | 622 MHz | 631.25 mV | **581.25 mV** | 750.00 mV | **750.00 mV** | 168.75 mV |
| 37 | 570 MHz | 618.75 mV | **568.75 mV** | 750.00 mV | **750.00 mV** | 181.25 mV |
| 40 | 493 MHz | 600.00 mV | **550.00 mV** | 750.00 mV | **750.00 mV** | 200.00 mV |
| 44 (Min) | 390 MHz | 575.00 mV | **550.00 mV** | 750.00 mV | **750.00 mV** | 200.00 mV |

---

## 4. DVFSRC Vcore Voltage Table (MT6853 / MT6833)

### 4.1 Operating Voltage Levels
The SoC digital core rail (`dvfsrc-vcore`, regulator.3) operates on 4 discrete voltage steps:

| Level | Stock Voltage | Patched Voltage | Hardware PMIC 0x152c Step | Note |
| :---: | :---: | :---: | :---: | :--- |
| 0 | 550.00 mV (550000 uV) | **550.00 mV** | `0x07` (7) | Idle / Deep Sleep Floor |
| 1 | 600.00 mV (600000 uV) | **600.00 mV** | `0x0f` (15) | Low Power Interconnect |
| 2 | 650.00 mV (650000 uV) | **650.00 mV** | `0x17` (23) | Nominal Performance (**New Capped Ceiling**) |
| 3 | 725.00 mV (725000 uV) | **650.00 mV** | `0x17` (23) | **Clamped from 725.00 mV (-75.00 mV Net)** |

### 4.2 Full DVFSRC OPP Table (25 Operating Performance Points)
Each operating point pairs memory clock frequency (DDR) with Vcore voltage level:

| OPP Index | DDR Frequency | Stock Vcore | Patched Vcore | Net Delta | Active Consumers |
| :---: | :---: | :---: | :---: | :---: | :--- |
| OPP 0 | 4266 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | 120Hz Display, Peak Burst I/O |
| OPP 1 | 3200 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | 120Hz Display, High Throughput |
| OPP 2 | 3200 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | High Throughput Memory |
| OPP 3 | 2400 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | Dynamic Display Scaling |
| OPP 4 | 2400 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | Balanced High OPP |
| OPP 5 | 2400 MHz | 600.00 mV | **600.00 mV** | 0.00 mV | Balanced Normal OPP |
| OPP 6 | 1866 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | Video Decode Burst |
| OPP 7 | 1866 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | Medium Display Load |
| OPP 8 | 1866 MHz | 600.00 mV | **600.00 mV** | 0.00 mV | Medium Load |
| OPP 9 | 1600 MHz | 725.00 mV | **650.00 mV** | **-75.00 mV** | Display Transition |
| OPP 10 | 1600 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | Moderate Throughput |
| OPP 11 | 1600 MHz | 600.00 mV | **600.00 mV** | 0.00 mV | Power Saving |
| OPP 12 | 1600 MHz | 550.00 mV | **550.00 mV** | 0.00 mV | Idle Power Saving |
| OPP 13 | 1200 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | Moderate Bus Load |
| OPP 14 | 1200 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | Moderate Bus Load |
| OPP 15 | 1200 MHz | 600.00 mV | **600.00 mV** | 0.00 mV | Low Power Bus |
| OPP 16 | 1200 MHz | 550.00 mV | **550.00 mV** | 0.00 mV | Low Power Bus |
| OPP 17 | 800 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | UI Idle Active |
| OPP 18 | 800 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | UI Idle Active |
| OPP 19 | 800 MHz | 600.00 mV | **600.00 mV** | 0.00 mV | Deep Idle State |
| OPP 20 | 800 MHz | 550.00 mV | **550.00 mV** | 0.00 mV | Deep Idle State |
| OPP 21 | 400 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | Screen-Off Audio |
| OPP 22 | 400 MHz | 650.00 mV | **650.00 mV** | 0.00 mV | Screen-Off Audio |
| OPP 23 | 400 MHz | 600.00 mV | **600.00 mV** | 0.00 mV | Screen-Off Sleep |
| OPP 24 | 400 MHz | 550.00 mV | **550.00 mV** | 0.00 mV | Deep Sleep Baseline |

---

## 5. Calibrated Upower EAS Energy Model Tables (`Upower.ko`)

### 5.1 Little Cluster Energy Table (`upower_tbl_l_B24G`)
* Capacity Range: 147 (200 MHz underclock floor) – 356 (2000 MHz maximum)
* Efficiency Evaluation: Lower values indicate superior power efficiency.
* `turn_point` calibrated to **2 (500 MHz)** on live hardware (matching `/proc/upower/upower_debug`), shifted by the 200 MHz Big core underclock floor.

| Upower OPP | CPU_DVFS OPP | Frequency | Stock Volt | Patched Volt | Stock Dyn Power | Patched Dyn Power | Power Delta | Efficiency (eff) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 15 | **200 MHz** | 650.00 mV | **581.25 mV** | 17,036 uW | **7,083 uW** | **-58.4%** | 214 (static) / 340 (live) |
| 1 | 14 | 500 MHz | 650.00 mV | **593.75 mV** | 22,147 uW | **18,479 uW** | **-16.6%** | **237 (turn_pt, static)** / **339 (turn_pt, live)** |
| 2 | 13 | 703 MHz | 662.50 mV | **625.00 mV** | 24,883 uW | **22,145 uW** | **-11.0%** | 245 (static) / 353 (live) |
| 3 | 12 | 756 MHz | 675.00 mV | **637.50 mV** | 27,778 uW | **24,777 uW** | **-10.8%** | 250 (static) / 358 (live) |
| 4 | 11 | 862 MHz | 700.00 mV | **662.50 mV** | 34,063 uW | **30,511 uW** | **-10.4%** | 263 (static) / 368 (live) |
| 5 | 10 | 968 MHz | 725.00 mV | **675.00 mV** | 41,033 uW | **35,568 uW** | **-13.3%** | 272 (static) / 366 (live) |
| 6 | 9 | 1048 MHz | 743.75 mV | **693.75 mV** | 46,751 uW | **40,676 uW** | **-13.0%** | 287 (static) / 384 (live) |
| 7 | 8 | 1128 MHz | 762.50 mV | **712.50 mV** | 52,357 uW | **45,715 uW** | **-12.7%** | 295 (static) / 392 (live) |
| 8 | 7 | 1287 MHz | 800.00 mV | **750.00 mV** | 64,430 uW | **56,627 uW** | **-12.1%** | 323 (static) / 419 (live) |
| 9 | 6 | 1393 MHz | 825.00 mV | **775.00 mV** | 73,144 uW | **64,546 uW** | **-11.8%** | 339 (static) / 435 (live) |
| 10 | 5 | 1500 MHz | 850.00 mV | **800.00 mV** | 82,433 uW | **73,020 uW** | **-11.4%** | 365 (static) / 467 (live) |
| 11 | 4 | 1645 MHz | 893.75 mV | **843.75 mV** | 97,153 uW | **86,586 uW** | **-10.9%** | 405 (static) / 514 (live) |
| 12 | 3 | 1750 MHz | 925.00 mV | **875.00 mV** | 108,403 uW | **97,000 uW** | **-10.5%** | 434 (static) / 546 (live) |
| 13 | 2 | 1812 MHz | 943.75 mV | **893.75 mV** | 115,373 uW | **103,471 uW** | **-10.3%** | 453 (static) / 569 (live) |
| 14 | 1 | 1916 MHz | 975.00 mV | **925.00 mV** | 127,431 uW | **114,696 uW** | **-10.0%** | 484 (static) / 607 (live) |
| 15 | 0 | 2000 MHz | 1000.00 mV | **950.00 mV** | 137,463 uW | **124,060 uW** | **-9.7%** | 512 (static) / 640 (live) |

---

### 5.2 Big Cluster Energy Table (`upower_tbl_b_B24G`)
* Capacity Range: 611 (200 MHz underclock floor) – 1024 (2400 MHz maximum)

| Upower OPP | CPU_DVFS OPP | Frequency | Stock Volt | Patched Volt | Stock Dyn Power | Patched Dyn Power | Power Delta | Efficiency (eff) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 15 | **200 MHz** | 650.00 mV | **581.25 mV** | 88,853 uW | **32,928 uW** | **-62.9%** | **224 (min_eff, static)** / **340 (min_eff, live)** |
| 1 | 14 | 500 MHz | 681.25 mV | **593.75 mV** | 113,084 uW | **85,900 uW** | **-24.0%** | 297 (static) / 391 (live) |
| 2 | 13 | 898 MHz | 693.75 mV | **656.25 mV** | 125,369 uW | **112,181 uW** | **-10.5%** | 326 (static) / 447 (live) |
| 3 | 12 | 985 MHz | 718.75 mV | **681.25 mV** | 147,605 uW | **132,604 uW** | **-10.2%** | 349 (static) / 472 (live) |
| 4 | 11 | 1042 MHz | 737.50 mV | **687.50 mV** | 164,400 uW | **142,864 uW** | **-13.1%** | 359 (static) / 475 (live) |
| 5 | 10 | 1129 MHz | 756.25 mV | **706.25 mV** | 186,497 uW | **162,651 uW** | **-12.8%** | 394 (static) / 516 (live) |
| 6 | 9 | 1274 MHz | 800.00 mV | **750.00 mV** | 233,693 uW | **205,394 uW** | **-12.1%** | 444 (static) / 572 (live) |
| 7 | 8 | 1418 MHz | 837.50 mV | **787.50 mV** | 282,870 uW | **250,102 uW** | **-11.6%** | 494 (static) / 628 (live) |
| 8 | 7 | 1534 MHz | 868.75 mV | **818.75 mV** | 327,217 uW | **290,635 uW** | **-11.2%** | 540 (static) / 678 (live) |
| 9 | 6 | 1650 MHz | 900.00 mV | **850.00 mV** | 374,804 uW | **334,315 uW** | **-10.8%** | 586 (static) / 731 (live) |
| 10 | 5 | 1837 MHz | 937.50 mV | **887.50 mV** | 443,644 uW | **397,583 uW** | **-10.4%** | 650 (static) / 801 (live) |
| 11 | 4 | 1993 MHz | 968.75 mV | **918.75 mV** | 505,112 uW | **454,316 uW** | **-10.1%** | 712 (static) / 873 (live) |
| 12 | 3 | 2118 MHz | 993.75 mV | **943.75 mV** | 556,944 uW | **502,309 uW** | **-9.8%** | 756 (static) / 922 (live) |
| 13 | 2 | 2203 MHz | 1012.50 mV | **962.50 mV** | 597,446 uW | **539,895 uW** | **-9.6%** | 792 (static) / 963 (live) |
| 14 | 1 | 2306 MHz | 1031.25 mV | **981.25 mV** | 646,701 uW | **585,510 uW** | **-9.5%** | 836 (static) / 1012 (live) |
| 15 | 0 | 2400 MHz | 1050.00 mV | **1000.00 mV** | 697,760 uW | **632,888 uW** | **-9.3%** | 883 (static) / 1065 (live) |

---

### 5.3 CCI Interconnect Energy Table (`upower_tbl_cci_B24G`)

| Upower OPP | CPU_DVFS OPP | Frequency | Stock Volt | Patched Volt | Stock Dyn Power | Patched Dyn Power | Power Delta |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 15 | 450 MHz | 650.00 mV | **618.75 mV** | 8,189 uW | **7,420 uW** | **-9.4%** |
| 1 | 14 | 487 MHz | 662.50 mV | **631.25 mV** | 9,207 uW | **8,358 uW** | **-9.2%** |
| 2 | 13 | 525 MHz | 675.00 mV | **643.75 mV** | 10,303 uW | **9,371 uW** | **-9.0%** |
| 3 | 12 | 562 MHz | 687.50 mV | **656.25 mV** | 11,442 uW | **10,425 uW** | **-8.9%** |
| 4 | 11 | 600 MHz | 700.00 mV | **668.75 mV** | 12,663 uW | **11,557 uW** | **-8.7%** |
| 5 | 10 | 675 MHz | 725.00 mV | **693.75 mV** | 15,282 uW | **13,992 uW** | **-8.4%** |
| 6 | 9 | 768 MHz | 756.25 mV | **718.75 mV** | 18,919 uW | **17,089 uW** | **-9.7%** |
| 7 | 8 | 825 MHz | 775.00 mV | **737.50 mV** | 21,343 uW | **19,327 uW** | **-9.4%** |
| 8 | 7 | 900 MHz | 800.00 mV | **762.50 mV** | 24,810 uW | **22,538 uW** | **-9.2%** |
| 9 | 6 | 975 MHz | 825.00 mV | **787.50 mV** | 28,584 uW | **26,044 uW** | **-8.9%** |
| 10 | 5 | 1050 MHz | 850.00 mV | **812.50 mV** | 32,676 uW | **29,856 uW** | **-8.6%** |
| 11 | 4 | 1141 MHz | 875.00 mV | **837.50 mV** | 37,627 uW | **34,470 uW** | **-8.4%** |
| 12 | 3 | 1210 MHz | 893.75 mV | **856.25 mV** | 41,631 uW | **38,210 uW** | **-8.2%** |
| 13 | 2 | 1370 MHz | 937.50 mV | **900.00 mV** | 51,864 uW | **47,797 uW** | **-7.8%** |
| 14 | 1 | 1531 MHz | 981.25 mV | **943.75 mV** | 63,495 uW | **58,734 uW** | **-7.5%** |
| 15 | 0 | 1600 MHz | 1000.00 mV | **962.50 mV** | 68,917 uW | **63,845 uW** | **-7.4%** |
