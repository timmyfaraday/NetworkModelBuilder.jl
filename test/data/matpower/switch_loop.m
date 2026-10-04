% Three buses round a loop: a cheap generator at 1, a dear one at 3 and the load at 2,
% behind two rated branches. The switches the cross-check against PowerModels.jl puts
% in the loop are added by the test, since a Matpower file has no switch table.
% linear objective function

function mpc = switch_loop
mpc.version = '2';
mpc.baseMVA = 100.0;
mpc.bus = [
        1        3       0.0     0.0     0.0     0.0     1          1.00000        0.00000      240.0   1          1.10000         0.90000;
        2        1       180.0   0.0     0.0     0.0     1          1.00000        0.00000      240.0   1          1.10000         0.90000;
        3        1       0.0     0.0     0.0     0.0     1          1.00000        0.00000      240.0   1          1.10000         0.90000;
];

mpc.gen = [
        1        0.0     0.0     500.0   -500.0  1.0     100.0   1       500.0   0.0;
        3        0.0     0.0     500.0   -500.0  1.0     100.0   1       500.0   0.0;
];

mpc.gencost = [
        2        0.0     0.0     2         1.000000        0.000000;
        2        0.0     0.0     2         10.000000       0.000000;
];

mpc.branch = [
        1        2       0.0     0.1     0.0     100.0   0.0     0.0   0.0      0.0     1       -30.0   30.0;
        3        2       0.0     0.1     0.0     150.0   0.0     0.0   0.0      0.0     1       -30.0   30.0;
];
