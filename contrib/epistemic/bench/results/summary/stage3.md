# Stage 3 results (F12)

Real dataset replay across 7 systems × 3 concurrency levels.
See DECISIONS.md for design notes and honest-scope caveats.

## longmemeval

Full trace: 156 writes. See `bench/datasets/longmemeval/README.md` for provenance and mapping.

| system | c | n_writes | tps | abort_rate | AA | integrity | goodput | elapsed_s | CRS |
|---|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 156 | 4945.5 | 0.500 | 0.000 | PASS | 0.0 | 0.02 | 0.000 |
| epistemic | 8 | 156 | 1942.4 | 0.673 | 0.256 | PASS | 162.8 | 0.03 | 0.256 |
| epistemic | 32 | 156 | 693.9 | 0.814 | 0.154 | PASS | 19.8 | 0.04 | 0.154 |
| pg_conf | 1 | 156 | 4703.9 | 0.500 | 0.000 | PASS | 0.0 | 0.02 | 0.000 |
| pg_conf | 8 | 156 | 1791.5 | 0.692 | 0.205 | NOT_MEASURED | 113.1 | 0.03 | 0.205 |
| pg_conf | 32 | 156 | 478.7 | 0.853 | 0.090 | NOT_MEASURED | 6.3 | 0.05 | 0.090 |
| pg_heap | 1 | 156 | 12619.3 | 0.000 | 0.000 | NOT_MEASURED | 0.0 | 0.01 | 0.000 |
| pg_heap | 8 | 156 | 5697.6 | 0.000 | 0.410 | NOT_MEASURED | 2337.5 | 0.03 | 0.410 |
| pg_heap | 32 | 156 | 3876.7 | 0.000 | 0.474 | NOT_MEASURED | 1839.0 | 0.04 | 0.474 |
| pg_llm | 1 | 100 | 0.9 | 0.490 | 0.020 | PASS | 0.0 | 57.99 | 0.020 |
| pg_llm | 8 | 100 | 21.8 | 0.660 | 0.240 | NOT_MEASURED | 1.8 | 1.56 | 0.240 |
| pg_llm | 32 | 100 | 8.5 | 0.830 | 0.160 | NOT_MEASURED | 0.2 | 1.99 | 0.160 |
| pg_lww | 1 | 156 | 10026.8 | 0.000 | 0.974 | PASS | 9769.7 | 0.02 | 0.974 |
| pg_lww | 8 | 156 | 1687.6 | 0.699 | 0.231 | NOT_MEASURED | 117.3 | 0.03 | 0.231 |
| pg_lww | 32 | 156 | 507.4 | 0.859 | 0.141 | NOT_MEASURED | 10.1 | 0.04 | 0.141 |
| pg_mv | 1 | 156 | 4191.1 | 0.500 | 0.000 | PASS | 0.0 | 0.02 | 0.000 |
| pg_mv | 8 | 156 | 1692.5 | 0.712 | 0.218 | NOT_MEASURED | 106.4 | 0.03 | 0.218 |
| pg_mv | 32 | 156 | 457.9 | 0.865 | 0.115 | NOT_MEASURED | 7.1 | 0.05 | 0.115 |
| pg_trigger | 1 | 156 | 4617.1 | 0.500 | 0.000 | PASS | 0.0 | 0.02 | 0.000 |
| pg_trigger | 8 | 156 | 1721.1 | 0.705 | 0.205 | PASS | 104.1 | 0.03 | 0.205 |
| pg_trigger | 32 | 156 | 561.3 | 0.840 | 0.154 | PASS | 13.8 | 0.04 | 0.154 |

## memoryagentbench

Full trace: 37820 writes. See `bench/datasets/memoryagentbench/README.md` for provenance and mapping.

| system | c | n_writes | tps | abort_rate | AA | integrity | goodput | elapsed_s |
|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 37820 | 2439.6 | 0.379 | 0.000 | PASS | 0.0 | 9.63 |
| epistemic | 8 | 37820 | 2199.9 | 0.762 | 0.261 | PASS | 136.8 | 4.10 |
| epistemic | 32 | 37820 | 810.2 | 0.866 | 0.139 | PASS | 15.1 | 6.27 |
| pg_conf | 1 | 37820 | 1471.8 | 0.379 | 0.000 | PASS | 0.0 | 15.96 |
| pg_conf | 8 | 37820 | 1665.0 | 0.787 | 0.207 | NOT_MEASURED | 73.4 | 4.84 |
| pg_conf | 32 | 37820 | 723.8 | 0.876 | 0.121 | NOT_MEASURED | 10.9 | 6.46 |
| pg_heap | 1 | 37820 | 18636.3 | 0.000 | 0.000 | NOT_MEASURED | 0.0 | 2.03 |
| pg_heap | 8 | 37820 | 7151.8 | 0.000 | 0.501 | NOT_MEASURED | 3579.9 | 5.29 |
| pg_heap | 32 | 37820 | 6973.2 | 0.000 | 0.503 | NOT_MEASURED | 3506.6 | 5.42 |
| pg_llm | 1 | 100 | 1.6 | 0.320 | 0.111 | PASS | 0.1 | 42.40 |
| pg_llm | 8 | 100 | 18.8 | 0.670 | 0.167 | NOT_MEASURED | 1.0 | 1.76 |
| pg_llm | 32 | 100 | 7.9 | 0.850 | 0.083 | NOT_MEASURED | 0.1 | 1.89 |
| pg_lww | 1 | 37820 | 1199.8 | 0.000 | 1.000 | PASS | 1199.8 | 31.52 |
| pg_lww | 8 | 37820 | 1716.6 | 0.776 | 0.223 | NOT_MEASURED | 85.7 | 4.93 |
| pg_lww | 32 | 37820 | 776.5 | 0.871 | 0.123 | NOT_MEASURED | 12.3 | 6.28 |
| pg_mv | 1 | 37820 | 1228.4 | 0.179 | 0.527 | PASS | 531.1 | 25.27 |
| pg_mv | 8 | 37820 | 1664.3 | 0.788 | 0.207 | NOT_MEASURED | 73.3 | 4.83 |
| pg_mv | 32 | 37820 | 738.1 | 0.876 | 0.121 | NOT_MEASURED | 11.0 | 6.35 |
| pg_trigger | 1 | 37820 | 852.8 | 0.379 | 0.000 | PASS | 0.0 | 27.54 |
| pg_trigger | 8 | 37820 | 1598.6 | 0.818 | 0.177 | PASS | 51.7 | 4.31 |
| pg_trigger | 32 | 37820 | 690.9 | 0.879 | 0.121 | PASS | 10.1 | 6.60 |

## mquake

Full trace: 12030 writes. See `bench/datasets/mquake/README.md` for provenance and mapping.

| system | c | n_writes | tps | abort_rate | AA | integrity | goodput | elapsed_s | UOCS | cases_ok |
|---|---|---|---|---|---|---|---|---|---|---|
| epistemic | 1 | 12030 | 4016.3 | 0.500 | 0.000 | PASS | 0.0 | 1.50 | 0.000 | 0/3000 |
| epistemic | 8 | 12030 | 2308.6 | 0.702 | 0.291 | PASS | 199.9 | 1.55 | 0.135 | 406/3000 |
| epistemic | 32 | 12030 | 908.6 | 0.857 | 0.139 | PASS | 18.1 | 1.90 | 0.058 | 173/3000 |
| pg_conf | 1 | 12030 | 2956.3 | 0.500 | 0.000 | PASS | 0.0 | 2.04 | 0.000 | 0/3000 |
| pg_conf | 8 | 12030 | 1848.1 | 0.741 | 0.247 | NOT_MEASURED | 117.9 | 1.69 | 0.102 | 306/3000 |
| pg_conf | 32 | 12030 | 789.7 | 0.873 | 0.123 | NOT_MEASURED | 12.3 | 1.93 | 0.049 | 146/3000 |
| pg_heap | 1 | 12030 | 19288.5 | 0.000 | 0.000 | NOT_MEASURED | 0.0 | 0.62 | 0.000 | 0/3000 |
| pg_heap | 8 | 12030 | 7338.1 | 0.000 | 0.500 | NOT_MEASURED | 3667.2 | 1.64 | 0.300 | 900/3000 |
| pg_heap | 32 | 12030 | 7022.6 | 0.000 | 0.505 | NOT_MEASURED | 3544.6 | 1.71 | 0.307 | 922/3000 |
| pg_llm | 1 | 100 | 1.1 | 0.450 | 0.100 | PASS | 0.1 | 51.63 | 0.100 | 5/50 |
| pg_llm | 8 | 100 | 28.0 | 0.660 | 0.300 | NOT_MEASURED | 2.9 | 1.22 | 0.300 | 15/50 |
| pg_llm | 32 | 100 | 14.8 | 0.840 | 0.220 | NOT_MEASURED | 0.5 | 1.08 | 0.220 | 11/50 |
| pg_lww | 1 | 12030 | 3218.9 | 0.000 | 1.000 | PASS | 3218.9 | 3.74 | 1.000 | 3000/3000 |
| pg_lww | 8 | 12030 | 1973.2 | 0.730 | 0.268 | NOT_MEASURED | 143.0 | 1.65 | 0.110 | 331/3000 |
| pg_lww | 32 | 12030 | 837.4 | 0.867 | 0.124 | NOT_MEASURED | 13.8 | 1.91 | 0.049 | 147/3000 |
| pg_mv | 1 | 12030 | 2763.7 | 0.258 | 0.485 | PASS | 994.2 | 3.23 | 0.266 | 799/3000 |
| pg_mv | 8 | 12030 | 1909.1 | 0.741 | 0.256 | NOT_MEASURED | 126.7 | 1.64 | 0.113 | 339/3000 |
| pg_mv | 32 | 12030 | 796.2 | 0.872 | 0.123 | NOT_MEASURED | 12.5 | 1.93 | 0.052 | 155/3000 |
| pg_trigger | 1 | 12030 | 1956.4 | 0.500 | 0.000 | PASS | 0.0 | 3.07 | 0.000 | 0/3000 |
| pg_trigger | 8 | 12030 | 1763.8 | 0.757 | 0.232 | PASS | 99.5 | 1.66 | 0.097 | 291/3000 |
| pg_trigger | 32 | 12030 | 795.5 | 0.870 | 0.125 | PASS | 13.0 | 1.97 | 0.048 | 145/3000 |

