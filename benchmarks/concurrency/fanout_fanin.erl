-module(fanout_fanin).
-export([main/0]).

main() ->
    N = 100000,
    NumWorkers = 8,
    PerWorker = N div NumWorkers,
    Self = self(),
    Start = erlang:monotonic_time(nanosecond),
    [spawn(fun() ->
        Sum = lists:sum(lists:seq(I * PerWorker, (I + 1) * PerWorker - 1)),
        Self ! {result, Sum}
    end) || I <- lists:seq(0, NumWorkers - 1)],
    Total = collect(NumWorkers, 0),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    Rate = N * 1000000000 div Elapsed,
    io:format("BENCH:fanout_fanin:items_per_sec:~p~n", [Rate]),
    io:format("BENCH:fanout_fanin:elapsed_ns:~p~n", [Elapsed]),
    io:format("BENCH:fanout_fanin:total:~p~n", [Total]),
    halt(0).

collect(0, Acc) -> Acc;
collect(N, Acc) ->
    receive {result, V} -> collect(N - 1, Acc + V) end.
