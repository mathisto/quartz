-module(contention).
-export([main/0]).

main() ->
    NumTasks = 8,
    TotalOps = 1000000,
    ItersPerTask = TotalOps div NumTasks,
    Counter = atomics:new(1, [{signed, true}]),
    Self = self(),
    Start = erlang:monotonic_time(nanosecond),
    [spawn(fun() ->
        increment(Counter, ItersPerTask),
        Self ! done
    end) || _ <- lists:seq(1, NumTasks)],
    wait(NumTasks),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    Total = atomics:get(Counter, 1),
    Rate = Total * 1000000000 div Elapsed,
    io:format("BENCH:contention:ops_per_sec:~p~n", [Rate]),
    io:format("BENCH:contention:elapsed_ns:~p~n", [Elapsed]),
    io:format("BENCH:contention:total_ops:~p~n", [Total]),
    halt(0).

increment(_Counter, 0) -> ok;
increment(Counter, N) ->
    atomics:add(Counter, 1, 1),
    increment(Counter, N - 1).

wait(0) -> ok;
wait(N) -> receive done -> wait(N - 1) end.
