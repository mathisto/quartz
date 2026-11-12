-module(wake_burst).
-export([main/0]).

main() ->
    N = 10000,
    Self = self(),
    %% Spawn workers, each waits for a wake message
    Pids = [spawn(fun() ->
        receive wake -> ok end,
        Self ! done
    end) || _ <- lists:seq(1, N)],
    %% Let all processes park
    timer:sleep(10),
    %% Burst-send to wake all
    Start = erlang:monotonic_time(nanosecond),
    [Pid ! wake || Pid <- Pids],
    wait(N),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    Rate = N * 1000000000 div Elapsed,
    io:format("BENCH:wake_burst:wakes_per_sec:~p~n", [Rate]),
    io:format("BENCH:wake_burst:elapsed_ns:~p~n", [Elapsed]),
    halt(0).

wait(0) -> ok;
wait(N) -> receive done -> wait(N - 1) end.
