-module(memory_efficiency).
-export([main/0]).

main() ->
    N = 100000,
    MemBefore = erlang:memory(total),
    %% Spawn processes that block (stay alive for measurement)
    Pids = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, N)],
    MemAfter = erlang:memory(total),
    Delta = MemAfter - MemBefore,
    BytesPerTask = Delta div N,
    %% Cleanup
    [Pid ! stop || Pid <- Pids],
    io:format("BENCH:memory_efficiency:bytes_per_task:~p~n", [BytesPerTask]),
    io:format("BENCH:memory_efficiency:total_bytes:~p~n", [Delta]),
    io:format("BENCH:memory_efficiency:processes:~p~n", [N]),
    halt(0).
