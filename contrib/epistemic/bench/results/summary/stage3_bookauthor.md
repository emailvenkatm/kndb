# Stage 3 Book-Author results (F13)

Dong VLDB'09 Book-Author dataset. Ground truth = cover-truth author lists (100 gold ISBN-10 books). Source-tier mapping computed from structural properties of `book.txt` (n_listings + canon_rate); see `bench/datasets/bookauthor/README.md`.


## K = 10

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 2861 | 622.8 | 0.937 | 0.610 | PASS | 23.8 | 0.29 |
| epistemic | 8 | 2861 | 431.6 | 0.937 | 0.610 | PASS | 16.5 | 0.41 |
| epistemic | 32 | 2861 | 321.1 | 0.943 | 0.630 | PASS | 11.5 | 0.51 |
| pg_conf | 1 | 2861 | 763.3 | 0.929 | 0.600 | PASS | 32.7 | 0.27 |
| pg_conf | 8 | 2861 | 417.4 | 0.930 | 0.610 | PASS | 17.9 | 0.48 |
| pg_conf | 32 | 2861 | 369.0 | 0.937 | 0.600 | PASS | 13.9 | 0.49 |
| pg_heap | 1 | 2861 | 15006.3 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 10654.4 | 0.19 |
| pg_heap | 8 | 2861 | 6814.5 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 4293.1 | 0.42 |
| pg_heap | 32 | 2861 | 6218.9 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3047.3 | 0.46 |
| pg_lww | 1 | 2861 | 5902.3 | 0.000 | 0.360 | PASS | 2124.8 | 0.48 |
| pg_lww | 8 | 2861 | 2041.8 | 0.712 | 0.510 | PASS | 300.3 | 0.40 |
| pg_lww | 32 | 2861 | 636.9 | 0.890 | 0.610 | PASS | 42.9 | 0.50 |
| pg_mv | 1 | 2861 | 1497.5 | 0.842 | 0.590 | PASS | 139.9 | 0.30 |
| pg_mv | 8 | 2861 | 830.6 | 0.866 | 0.490 | PASS | 54.6 | 0.46 |
| pg_mv | 32 | 2861 | 472.6 | 0.919 | 0.470 | PASS | 18.1 | 0.49 |
| pg_trigger | 1 | 2861 | 485.5 | 0.957 | 0.590 | PASS | 12.2 | 0.25 |
| pg_trigger | 8 | 2861 | 281.0 | 0.957 | 0.650 | PASS | 7.8 | 0.43 |
| pg_trigger | 32 | 2861 | 258.1 | 0.957 | 0.700 | PASS | 7.8 | 0.48 |

## K = 25

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 2861 | 634.9 | 0.938 | 0.510 | PASS | 19.9 | 0.28 |
| epistemic | 8 | 2861 | 411.1 | 0.938 | 0.510 | PASS | 12.9 | 0.43 |
| epistemic | 32 | 2861 | 277.2 | 0.945 | 0.550 | PASS | 8.4 | 0.57 |
| pg_conf | 1 | 2861 | 634.9 | 0.929 | 0.510 | PASS | 22.9 | 0.32 |
| pg_conf | 8 | 2861 | 394.2 | 0.934 | 0.540 | PASS | 14.1 | 0.48 |
| pg_conf | 32 | 2861 | 327.2 | 0.941 | 0.500 | PASS | 9.7 | 0.52 |
| pg_heap | 1 | 2861 | 15298.6 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 10403.0 | 0.19 |
| pg_heap | 8 | 2861 | 6182.1 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3709.3 | 0.46 |
| pg_heap | 32 | 2861 | 6174.3 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3395.9 | 0.46 |
| pg_lww | 1 | 2861 | 6449.5 | 0.000 | 0.360 | PASS | 2321.8 | 0.44 |
| pg_lww | 8 | 2861 | 1742.5 | 0.721 | 0.500 | PASS | 242.7 | 0.46 |
| pg_lww | 32 | 2861 | 609.8 | 0.889 | 0.560 | PASS | 38.0 | 0.52 |
| pg_mv | 1 | 2861 | 1253.7 | 0.842 | 0.590 | PASS | 117.1 | 0.36 |
| pg_mv | 8 | 2861 | 791.9 | 0.881 | 0.480 | PASS | 45.2 | 0.43 |
| pg_mv | 32 | 2861 | 408.7 | 0.925 | 0.510 | PASS | 15.7 | 0.53 |
| pg_trigger | 1 | 2861 | 436.2 | 0.955 | 0.510 | PASS | 10.0 | 0.29 |
| pg_trigger | 8 | 2861 | 245.6 | 0.957 | 0.480 | PASS | 5.1 | 0.51 |
| pg_trigger | 32 | 2861 | 249.2 | 0.954 | 0.540 | PASS | 6.2 | 0.53 |

## K = 50

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 2861 | 656.2 | 0.937 | 0.540 | PASS | 22.2 | 0.27 |
| epistemic | 8 | 2861 | 402.6 | 0.940 | 0.550 | PASS | 13.4 | 0.43 |
| epistemic | 32 | 2861 | 277.6 | 0.944 | 0.540 | PASS | 8.4 | 0.58 |
| pg_conf | 1 | 2861 | 747.8 | 0.927 | 0.540 | PASS | 29.5 | 0.28 |
| pg_conf | 8 | 2861 | 429.8 | 0.932 | 0.600 | PASS | 17.5 | 0.45 |
| pg_conf | 32 | 2861 | 324.9 | 0.943 | 0.580 | PASS | 10.7 | 0.50 |
| pg_heap | 1 | 2861 | 13667.5 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 9567.3 | 0.21 |
| pg_heap | 8 | 2861 | 6240.4 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3744.2 | 0.46 |
| pg_heap | 32 | 2861 | 6343.3 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 2981.4 | 0.45 |
| pg_llm | 1 | 320 | 0.1 | 0.856 | 0.750 | PASS | 0.0 | 332.08 |
| pg_lww | 1 | 2861 | 5958.9 | 0.000 | 0.360 | PASS | 2145.2 | 0.48 |
| pg_lww | 8 | 2861 | 2073.1 | 0.719 | 0.490 | PASS | 285.1 | 0.39 |
| pg_lww | 32 | 2861 | 659.9 | 0.891 | 0.540 | PASS | 39.0 | 0.47 |
| pg_mv | 1 | 2861 | 1516.1 | 0.842 | 0.590 | PASS | 141.6 | 0.30 |
| pg_mv | 8 | 2861 | 767.2 | 0.886 | 0.510 | PASS | 44.4 | 0.42 |
| pg_mv | 32 | 2861 | 476.6 | 0.920 | 0.490 | PASS | 18.8 | 0.48 |
| pg_trigger | 1 | 2861 | 466.9 | 0.949 | 0.540 | PASS | 12.8 | 0.31 |
| pg_trigger | 8 | 2861 | 289.6 | 0.952 | 0.600 | PASS | 8.3 | 0.47 |
| pg_trigger | 32 | 2861 | 267.9 | 0.954 | 0.620 | PASS | 7.7 | 0.49 |

## K = 100

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 2861 | 667.9 | 0.935 | 0.610 | PASS | 26.6 | 0.28 |
| epistemic | 8 | 2861 | 409.1 | 0.942 | 0.630 | PASS | 15.0 | 0.41 |
| epistemic | 32 | 2861 | 273.5 | 0.947 | 0.580 | PASS | 8.5 | 0.56 |
| pg_conf | 1 | 2861 | 776.2 | 0.935 | 0.610 | PASS | 30.9 | 0.24 |
| pg_conf | 8 | 2861 | 392.2 | 0.940 | 0.570 | PASS | 13.4 | 0.44 |
| pg_conf | 32 | 2861 | 305.1 | 0.947 | 0.590 | PASS | 9.6 | 0.50 |
| pg_heap | 1 | 2861 | 13814.3 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 9670.0 | 0.21 |
| pg_heap | 8 | 2861 | 6960.3 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 4524.2 | 0.41 |
| pg_heap | 32 | 2861 | 6138.4 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3314.7 | 0.47 |
| pg_lww | 1 | 2861 | 6266.9 | 0.000 | 0.360 | PASS | 2256.1 | 0.46 |
| pg_lww | 8 | 2861 | 2027.5 | 0.728 | 0.540 | PASS | 297.7 | 0.38 |
| pg_lww | 32 | 2861 | 651.2 | 0.887 | 0.530 | PASS | 39.1 | 0.50 |
| pg_mv | 1 | 2861 | 1622.6 | 0.842 | 0.590 | PASS | 151.6 | 0.28 |
| pg_mv | 8 | 2861 | 722.9 | 0.886 | 0.540 | PASS | 44.5 | 0.45 |
| pg_mv | 32 | 2861 | 446.2 | 0.920 | 0.460 | PASS | 16.4 | 0.51 |
| pg_trigger | 1 | 2861 | 529.3 | 0.947 | 0.610 | PASS | 17.2 | 0.29 |
| pg_trigger | 8 | 2861 | 350.4 | 0.949 | 0.580 | PASS | 10.3 | 0.41 |
| pg_trigger | 32 | 2861 | 263.4 | 0.952 | 0.620 | PASS | 7.8 | 0.52 |

## K = 200

| system | c | n_writes | tps | abort_rate | Precision | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 2861 | 648.5 | 0.942 | 0.630 | PASS | 23.7 | 0.26 |
| epistemic | 8 | 2861 | 372.9 | 0.947 | 0.600 | PASS | 11.9 | 0.41 |
| epistemic | 32 | 2861 | 272.6 | 0.951 | 0.600 | PASS | 8.0 | 0.51 |
| pg_conf | 1 | 2861 | 646.3 | 0.944 | 0.630 | PASS | 22.6 | 0.25 |
| pg_conf | 8 | 2861 | 349.7 | 0.946 | 0.650 | PASS | 12.2 | 0.44 |
| pg_conf | 32 | 2861 | 266.6 | 0.950 | 0.580 | PASS | 7.7 | 0.54 |
| pg_heap | 1 | 2861 | 14600.7 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 10074.5 | 0.20 |
| pg_heap | 8 | 2861 | 6436.3 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3668.7 | 0.45 |
| pg_heap | 32 | 2861 | 5847.7 | 0.000 | INTEGRITY FAIL | FAIL (max=114, mean=28.6) | 3216.3 | 0.49 |
| pg_lww | 1 | 2861 | 6233.8 | 0.000 | 0.360 | PASS | 2244.2 | 0.46 |
| pg_lww | 8 | 2861 | 1916.1 | 0.727 | 0.520 | PASS | 272.3 | 0.41 |
| pg_lww | 32 | 2861 | 601.7 | 0.888 | 0.600 | PASS | 40.5 | 0.53 |
| pg_mv | 1 | 2861 | 1622.4 | 0.842 | 0.590 | PASS | 151.6 | 0.28 |
| pg_mv | 8 | 2861 | 693.2 | 0.886 | 0.510 | PASS | 40.4 | 0.47 |
| pg_mv | 32 | 2861 | 455.9 | 0.922 | 0.460 | PASS | 16.3 | 0.49 |
| pg_trigger | 1 | 2861 | 496.2 | 0.950 | 0.630 | PASS | 15.5 | 0.29 |
| pg_trigger | 8 | 2861 | 282.2 | 0.952 | 0.600 | PASS | 8.2 | 0.49 |
| pg_trigger | 32 | 2861 | 253.6 | 0.956 | 0.610 | PASS | 6.8 | 0.50 |

## Sensitivity of Precision to K (c=1)

Cells reading INTEGRITY FAIL had > 1 live row per (entity, attribute) slot at end-of-trace — the numeric "Precision" would only be a coin-flip on whichever duplicate the scanner returned first. Preserved under `Precision_ignoring_integrity` in the raw JSON.

| system | K=10 | K=25 | K=50 | K=100 | K=200 |
|---|---|---|---|---|---|
| epistemic | 0.610 | 0.510 | 0.540 | 0.610 | 0.630 |
| pg_conf | 0.600 | 0.510 | 0.540 | 0.610 | 0.630 |
| pg_heap | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL | INTEGRITY FAIL |
| pg_llm | - | - | 0.750 | - | - |
| pg_lww | 0.360 | 0.360 | 0.360 | 0.360 | 0.360 |
| pg_mv | 0.590 | 0.590 | 0.590 | 0.590 | 0.590 |
| pg_trigger | 0.590 | 0.510 | 0.540 | 0.610 | 0.630 |
