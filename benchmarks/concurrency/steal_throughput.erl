-module(steal_throughput).
-export([main/0]).

main() ->
    N = 100000,
    Self = self(),
    Start = erlang:monotonic_time(nanosecond),
    [spawn(fun() -> Self ! done end) || _ <- lists:seq(1, N)],
    wait(N),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    Rate = N * 1000000000 div Elapsed,
    io:format("BENCH:steal_throughput:tasks_per_sec:~p~n", [Rate]),
    io:format("BENCH:steal_throughput:elapsed_ns:~p~n", [Elapsed]),
    halt(0).

wait(0) -> ok;
wait(N) -> receive done -> wait(N - 1) end.
