-module(channel_throughput).
-export([main/0]).

main() ->
    N = 10000,
    Self = self(),
    Start = erlang:monotonic_time(nanosecond),
    Producer = spawn(fun() -> producer(Self, N) end),
    consumer(Producer, N, 0),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    Rate = N * 1000000000 div Elapsed,
    io:format("BENCH:channel_throughput:msgs_per_sec:~p~n", [Rate]),
    io:format("BENCH:channel_throughput:elapsed_ns:~p~n", [Elapsed]),
    halt(0).

producer(Consumer, 0) -> Consumer ! done;
producer(Consumer, N) ->
    Consumer ! {msg, N},
    producer(Consumer, N - 1).

consumer(_Producer, 0, _Sum) -> ok;
consumer(Producer, N, Sum) ->
    receive
        {msg, V} -> consumer(Producer, N - 1, Sum + V);
        done -> ok
    end.
