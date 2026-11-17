# MediaTek MT6833 DVFS & Voltage Table Reference

## 1. Voltage Step Formula (MT6359 PMIC)
The MT6359 PMIC uses linear voltage encoding:
$$\text{Voltage (mV)} = \text{Step} \times 6.25 + 400.0$$
$$\text{Voltage (uV)} = (\text{Step} \times 6.25 + 400.0) \times 1000$$

* Step `0` = $400.00\text{ mV}$
* Step `24` (`0x18`) = $550.00\text{ mV}$ (Hardware PMIC floor)
* Step `30` (`0x1e`) = $587.50\text{ mV}$
* Step `89` (`0x59`) = $956.25\text{ mV}$
* Step `97` (`0x61`) = $1006.25\text{ mV}$

---

## 2. CPU OPP Tables (Edge of the Cliff -43.75 mV Profile)

### Little Cluster (6x Cortex-A55)
* Stock Range: 500 MHz (550.00 mV eFuse / 650.00 mV nominal) – 2000 MHz (812.50 mV eFuse / 1000.00 mV nominal)
* Patched Range: **200 MHz (587.50 mV) – 2000 MHz (956.25 mV)**

| OPP Index | Frequency | Stock Nominal | Stock eFuse | Patched Nominal | Delta vs Stock | PLL Config (a, b) | VCO Freq |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 2000 MHz | 1000.00 mV | 812.50 mV | **956.25 mV** | -43.75 mV | (1, 1) | 2000 MHz |
| 1 | 1916 MHz |  975.00 mV | 787.50 mV | **931.25 mV** | -43.75 mV | (1, 1) | 1916 MHz |
| 2 | 1812 MHz |  943.75 mV | 750.00 mV | **900.00 mV** | -43.75 mV | (1, 1) | 1812 MHz |
| 3 | 1750 MHz |  925.00 mV | 731.25 mV | **881.25 mV** | -43.75 mV | (1, 1) | 1750 MHz |
| 4 | 1645 MHz |  893.75 mV | 693.75 mV | **850.00 mV** | -43.75 mV | (2, 1) | 3290 MHz |
| 5 | 1500 MHz |  850.00 mV | 643.75 mV | **806.25 mV** | -43.75 mV | (2, 1) | 3000 MHz |
| 6 | 1393 MHz |  825.00 mV | 637.50 mV | **781.25 mV** | -43.75 mV | (2, 1) | 2786 MHz |
| 7 | 1287 MHz |  800.00 mV | 625.00 mV | **756.25 mV** | -43.75 mV | (2, 1) | 2574 MHz |
| 8 | 1128 MHz |  762.50 mV | 606.25 mV | **718.75 mV** | -43.75 mV | (2, 1) | 2256 MHz |
| 9 | 1048 MHz |  743.75 mV | 600.00 mV | **700.00 mV** | -43.75 mV | (2, 1) | 2096 MHz |
| 10 |  968 MHz |  725.00 mV | 587.50 mV | **681.25 mV** | -43.75 mV | (2, 1) | 1936 MHz |
| 11 |  862 MHz |  700.00 mV | 581.25 mV | **668.75 mV** | -31.25 mV | (2, 1) | 1724 MHz |
| 12 |  756 MHz |  675.00 mV | 568.75 mV | **643.75 mV** | -31.25 mV | (4, 1) | 3024 MHz |
| 13 |  703 MHz |  662.50 mV | 562.50 mV | **631.25 mV** | -31.25 mV | (4, 1) | 2812 MHz |
| 14 |  500 MHz |  650.00 mV | 550.00 mV | **600.00 mV** | -50.00 mV | (4, 1) | 2000 MHz |
| 15 | **200 MHz** | *(unlocked)* | *(unlocked)* | **587.50 mV** | **Underclock** | (4, 2) | 1600 MHz |

---

### Big Cluster (2x Cortex-A76)
* Stock Range: 725 MHz (550.00 mV eFuse / 650.00 mV nominal) – 2400 MHz (781.25 mV eFuse / 1050.00 mV nominal)
* Patched Range: **200 MHz (587.50 mV) – 2400 MHz (1006.25 mV)**

| OPP Index | Frequency | Stock Nominal | Stock eFuse | Patched Nominal | Delta vs Stock | PLL Config (a, b) | VCO Freq |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 | 2400 MHz | 1050.00 mV | 781.25 mV | **1006.25 mV** | -43.75 mV | (1, 1) | 2400 MHz |
| 1 | 2306 MHz | 1031.25 mV | 762.50 mV | **987.50 mV** | -43.75 mV | (1, 1) | 2306 MHz |
| 2 | 2203 MHz | 1012.50 mV | 743.75 mV | **968.75 mV** | -43.75 mV | (1, 1) | 2203 MHz |
| 3 | 2118 MHz |  993.75 mV | 725.00 mV | **950.00 mV** | -43.75 mV | (1, 1) | 2118 MHz |
| 4 | 1993 MHz |  968.75 mV | 700.00 mV | **925.00 mV** | -43.75 mV | (1, 1) | 1993 MHz |
| 5 | 1837 MHz |  937.50 mV | 668.75 mV | **893.75 mV** | -43.75 mV | (1, 1) | 1837 MHz |
| 6 | 1650 MHz |  900.00 mV | 631.25 mV | **856.25 mV** | -43.75 mV | (2, 1) | 3300 MHz |
| 7 | 1534 MHz |  868.75 mV | 625.00 mV | **825.00 mV** | -43.75 mV | (2, 1) | 3068 MHz |
| 8 | 1418 MHz |  837.50 mV | 612.50 mV | **793.75 mV** | -43.75 mV | (2, 1) | 2836 MHz |
| 9 | 1274 MHz |  800.00 mV | 600.00 mV | **756.25 mV** | -43.75 mV | (2, 1) | 2548 MHz |
| 10 | 1129 MHz |  756.25 mV | 587.50 mV | **712.50 mV** | -43.75 mV | (2, 1) | 2258 MHz |
| 11 | 1042 MHz |  737.50 mV | 581.25 mV | **693.75 mV** | -43.75 mV | (2, 1) | 2084 MHz |
| 12 |  985 MHz |  718.75 mV | 575.00 mV | **687.50 mV** | -31.25 mV | (2, 1) | 1970 MHz |
| 13 |  898 MHz |  693.75 mV | 568.75 mV | **662.50 mV** | -31.25 mV | (2, 1) | 1796 MHz |
| 14 |  500 MHz |  681.25 mV | 562.50 mV | **600.00 mV** | -81.25 mV | (4, 1) | 2000 MHz |
| 15 | **200 MHz** | *(unlocked)* | 550.00 mV | **587.50 mV** | **Underclock** | (4, 2) | 1600 MHz |

---

## 3. GPU OPP Table (Mali-G57 MC2, -37.50 mV Profile)
The GPU table consists of 45 operating points inside `g_default_gpu` in `mtk_gpufreq_mt6833.ko`.

* **Hardware Limit**: $\Delta(V_{\text{sram}} - V_{\text{gpu}}) \le 200.00\text{ mV}$ (Strictly enforced by hardware).
* **Sample Key Steps**:

| OPP Index | Frequency | Stock Vgpu | Patched Vgpu | Stock Vsram | Patched Vsram | Delta (Vsram-Vgpu) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| 0 (Max) | 1068 MHz | 850.00 mV | **812.50 mV** | 850.00 mV | **812.50 mV** | 0.00 mV |
| 1 | 1058 MHz | 843.75 mV | **806.25 mV** | 843.75 mV | **806.25 mV** | 0.00 mV |
| 10 | 954 MHz | 793.75 mV | **756.25 mV** | 793.75 mV | **756.25 mV** | 0.00 mV |
| 20 | 800 MHz | 725.00 mV | **687.50 mV** | 750.00 mV | **750.00 mV** | 62.50 mV |
| 37 | 570 MHz | 618.75 mV | **581.25 mV** | 750.00 mV | **750.00 mV** | 168.75 mV |
| 44 (Min) | 390 MHz | 550.00 mV | **550.00 mV** | 750.00 mV | **750.00 mV** | 200.00 mV |
