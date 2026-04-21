-module(uaparser_ffi).
-export([cache_get/1, cache_put/2]).

cache_get(Key) ->
    try persistent_term:get(Key) of
        Val -> {ok, Val}
    catch
        error:badarg -> {error, nil}
    end.

cache_put(Key, Val) ->
    persistent_term:put(Key, Val),
    nil.
