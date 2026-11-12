-module(scalability_curve).
-export([main/0]).

main() ->
    Scales = [1000, 10000, 100000, 1000000],
    Rates = [spawn_and_wait(N) || N <- Scales],
    [Rate1k, _Rate10k, _Rate100k, Rate1m] = Rates,
    Efficiency = case Rate1k of
        0 -> 0;
        _ -> Rate1m * 1000 div Rate1k
    end,
    io:format("BENCH:scalability_curve:efficiency_x1000:~p~n", [Efficiency]),
    lists:foreach(fun({Scale, Rate}) ->
        io:format("BENCH:scalability_curve:rate_~pk:~p~n", [Scale div 1000, Rate])
    end, lists:zip(Scales, Rates)),
    halt(0).

spawn_and_wait(N) ->
    Self = self(),
    Start = erlang:monotonic_time(nanosecond),
    [spawn(fun() -> Self ! done end) || _ <- lists:seq(1, N)],
    wait(N),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    N * 1000000000 div Elapsed.

wait(0) -> ok;
wait(N) -> receive done -> wait(N - 1) end.
