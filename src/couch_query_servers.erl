% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_query_servers).

-export([start_doc_map/3, map_docs/2, map_docs_raw/2, stop_doc_map/1, raw_to_ejson/1]).
-export([reduce/3, rereduce/3,validate_doc_update/5]).
-export([filter_docs/5]).
-export([filter_view/3]).

-export([with_ddoc_proc/2, proc_prompt/2, ddoc_prompt/3, ddoc_proc_prompt/3, json_doc/1]).

% For 210-os-proc-pool.t
-export([get_os_process/1, ret_os_process/1]).

-include_lib("couch/include/couch_db.hrl").

-define(SUMERROR, <<"The _sum function requires that map values be numbers, "
    "arrays of numbers, or objects. Objects cannot be mixed with other data "
    "structures. Objects can be arbitrarily nested, provided that the values "
    "for all fields are themselves numbers, arrays of numbers, or objects.">>).

-define(STATERROR, <<"The _stats function requires that map values be numbers "
    "or arrays of numbers.">>).

% https://gist.github.com/df10284c76d85f988c3f
-define(SUMREGEX, {re_pattern,3,0,<<69,82,67,80,194,0,0,0,8,0,0,0,5,0,0,0,3,0,
2,0,0,0,125,2,48,0,9,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,118,97,108,
117,101,115,0,93,0,130,65,9,27,102,27,117,27,110,27,99,27,116,27,105,27,111,27,
110,102,94,0,9,0,1,66,9,58,11,84,0,9,65,9,27,40,65,9,58,11,65,9,27,44,56,9,94,
0,7,0,2,58,11,84,0,7,102,94,0,15,0,3,65,9,27,44,65,9,58,11,56,9,84,0,15,65,9,
27,41,65,9,27,123,65,9,27,114,27,101,27,116,27,117,27,114,27,110,66,9,27,115,
27,117,27,109,65,9,27,40,56,9,80,0,2,65,9,27,41,56,9,34,59,65,9,27,125,56,9,84,
0,130,0,0,0,0>>}).

% https://gist.github.com/cbd73238b671325f5a6f
-define(COUNTREGEX, {re_pattern,8,0,<<69,82,67,80,30,2,0,0,8,0,0,0,5,0,0,0,8,0,
4,0,0,0,125,2,48,0,11,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,114,101,
114,101,100,117,99,101,0,0,2,118,97,108,117,101,115,0,101,0,93,1,206,65,9,27,
102,27,117,27,110,27,99,27,116,27,105,27,111,27,110,102,94,0,9,0,1,66,9,58,11,
84,0,9,65,9,27,40,65,9,58,11,65,9,27,44,56,9,94,0,7,0,2,58,11,84,0,7,102,94,0,
23,0,3,65,9,27,44,56,9,94,0,7,0,4,58,11,84,0,7,56,9,84,0,23,65,9,27,41,65,9,27,
123,56,9,94,0,136,0,5,94,0,128,0,6,27,105,27,102,65,9,27,40,56,9,80,0,4,65,9,
27,41,56,9,34,123,65,9,27,114,27,101,27,116,27,117,27,114,27,110,66,9,27,115,
27,117,27,109,65,9,27,40,56,9,80,0,2,65,9,27,41,56,9,34,59,56,9,34,125,65,9,27,
101,27,108,27,115,27,101,56,9,34,123,65,9,27,114,27,101,27,116,27,117,27,114,
27,110,58,9,80,0,2,65,9,27,46,65,9,27,108,27,101,27,110,27,103,27,116,27,104,
56,9,34,59,56,9,34,125,84,0,128,83,0,138,94,0,132,0,7,27,105,27,102,65,9,27,40,
65,9,27,33,56,9,80,0,4,65,9,27,41,56,9,34,123,65,9,27,114,27,101,27,116,27,117,
27,114,27,110,58,9,80,0,2,65,9,27,46,65,9,27,108,27,101,27,110,27,103,27,116,
27,104,56,9,34,59,56,9,34,125,65,9,27,101,27,108,27,115,27,101,56,9,34,123,65,
9,27,114,27,101,27,116,27,117,27,114,27,110,66,9,27,115,27,117,27,109,65,9,27,
40,56,9,80,0,2,65,9,27,41,56,9,34,59,56,9,34,125,84,0,132,83,0,84,94,0,78,0,8,
27,114,27,101,27,116,27,117,27,114,27,110,58,9,80,0,4,65,9,27,63,65,9,27,115,
27,117,27,109,65,9,27,40,56,9,80,0,2,65,9,27,41,65,9,27,58,56,9,80,0,2,65,9,27,
46,65,9,27,108,27,101,27,110,27,103,27,116,27,104,56,9,34,59,84,0,78,84,1,102,
65,9,27,125,56,9,84,1,206,0,0,0,0,0,0,0>>}).

start_doc_map(Lang, Functions, Lib) ->
    Proc = get_os_process(Lang),
    case Lib of
    {[]} -> ok;
    Lib ->
        true = proc_prompt(Proc, [<<"add_lib">>, Lib])
    end,
    lists:foreach(fun(FunctionSource) ->
        true = proc_prompt(Proc, [<<"add_fun">>, FunctionSource])
    end, Functions),
    {ok, Proc}.

map_docs(Proc, Docs) ->
    % send the documents
    Results = lists:map(
        fun(Doc) ->
            Json = couch_doc:to_json_obj(Doc, []),

            FunsResults = proc_prompt(Proc, [<<"map_doc">>, Json]),
            % the results are a json array of function map yields like this:
            % [FunResults1, FunResults2 ...]
            % where funresults is are json arrays of key value pairs:
            % [[Key1, Value1], [Key2, Value2]]
            % Convert the key, value pairs to tuples like
            % [{Key1, Value1}, {Key2, Value2}]
            lists:map(
                fun(FunRs) ->
                    [list_to_tuple(FunResult) || FunResult <- FunRs]
                end,
            FunsResults)
        end,
        Docs),
    {ok, Results}.

map_docs_raw(Proc, DocList) ->
    {Mod, Fun} = Proc#proc.prompt_many_fun,
    CommandList = lists:map(
        fun(Doc) ->
            EJson = couch_doc:to_json_obj(Doc, []),
            [<<"map_doc">>, EJson]
        end,
        DocList),
    Mod:Fun(Proc#proc.pid, CommandList).

stop_doc_map(nil) ->
    ok;
stop_doc_map(Proc) ->
    ok = ret_os_process(Proc).

group_reductions_results([]) ->
    [];
group_reductions_results(List) ->
    {Heads, Tails} = lists:foldl(
        fun([H|T], {HAcc,TAcc}) ->
            {[H|HAcc], [T|TAcc]}
        end, {[], []}, List),
    case Tails of
    [[]|_] -> % no tails left
        [Heads];
    _ ->
     [Heads | group_reductions_results(Tails)]
    end.

rereduce(_Lang, [], _ReducedValues) ->
    {ok, []};
rereduce(Lang, RedSrcs, ReducedValues) ->
    Grouped = group_reductions_results(ReducedValues),
    Results = lists:zipwith(
        fun
        (<<"_", _/binary>> = FunSrc, Values) ->
            {ok, [Result]} = builtin_reduce(rereduce, [FunSrc], [[[], V] || V <- Values], []),
            Result;
        (FunSrc, Values) ->
            os_rereduce(Lang, [FunSrc], Values)
        end, replace_builtin_equivalents(RedSrcs), Grouped),
    {ok, Results}.

reduce(_Lang, [], _KVs) ->
    {ok, []};
reduce(Lang, RedSrcs0, KVs) ->
    RedSrcs = replace_builtin_equivalents(RedSrcs0),
    {OsRedSrcs, BuiltinReds} = lists:partition(fun
        (<<"_", _/binary>>) -> false;
        (_OsFun) -> true
    end, RedSrcs),
    {ok, OsResults} = os_reduce(Lang, OsRedSrcs, KVs),
    {ok, BuiltinResults} = builtin_reduce(reduce, BuiltinReds, KVs, []),
    recombine_reduce_results(RedSrcs, OsResults, BuiltinResults, []).

replace_builtin_equivalents([<<"_", _/binary>> = R | Rest]) ->
    [R | replace_builtin_equivalents(Rest)];
replace_builtin_equivalents([OsFun | Rest]) ->
    case re:run(OsFun, ?SUMREGEX) of nomatch ->
        case re:run(OsFun, ?COUNTREGEX) of nomatch ->
            [OsFun | replace_builtin_equivalents(Rest)];
        {match, _} ->
            [<<"_count">> | replace_builtin_equivalents(Rest)]
        end;
    {match, _} ->
        [<<"_sum">> | replace_builtin_equivalents(Rest)]
    end;
replace_builtin_equivalents([]) ->
    [].

recombine_reduce_results([], [], [], Acc) ->
    {ok, lists:reverse(Acc)};
recombine_reduce_results([<<"_", _/binary>>|RedSrcs], OsResults, [BRes|BuiltinResults], Acc) ->
    recombine_reduce_results(RedSrcs, OsResults, BuiltinResults, [BRes|Acc]);
recombine_reduce_results([_OsFun|RedSrcs], [OsR|OsResults], BuiltinResults, Acc) ->
    recombine_reduce_results(RedSrcs, OsResults, BuiltinResults, [OsR|Acc]).

os_reduce(_Lang, [], _KVs) ->
    {ok, []};
os_reduce(Lang, OsRedSrcs, KVs) ->
    Proc = get_os_process(Lang),
    OsResults = try proc_prompt(Proc, [<<"reduce">>, OsRedSrcs, KVs]) of
        [true, Reductions] -> Reductions
    after
        ok = ret_os_process(Proc)
    end,
    {ok, OsResults}.

os_rereduce(Lang, OsRedSrcs, KVs) ->
    Proc = get_os_process(Lang),
    try proc_prompt(Proc, [<<"rereduce">>, OsRedSrcs, KVs]) of
        [true, [Reduction]] -> Reduction
    after
        ok = ret_os_process(Proc)
    end.


builtin_reduce(_Re, [], _KVs, Acc) ->
    {ok, lists:reverse(Acc)};
builtin_reduce(Re, [<<"_sum",_/binary>>|BuiltinReds], KVs, Acc) ->
    Sum = builtin_sum_rows(KVs),
    builtin_reduce(Re, BuiltinReds, KVs, [Sum|Acc]);
builtin_reduce(reduce, [<<"_count",_/binary>>|BuiltinReds], KVs, Acc) ->
    Count = length(KVs),
    builtin_reduce(reduce, BuiltinReds, KVs, [Count|Acc]);
builtin_reduce(rereduce, [<<"_count",_/binary>>|BuiltinReds], KVs, Acc) ->
    Count = builtin_sum_rows(KVs),
    builtin_reduce(rereduce, BuiltinReds, KVs, [Count|Acc]);
builtin_reduce(Re, [<<"_stats",_/binary>>|BuiltinReds], KVs, Acc) ->
    Stats = builtin_stats(Re, KVs),
    builtin_reduce(Re, BuiltinReds, KVs, [Stats|Acc]).

builtin_sum_rows(KVs) ->
    lists:foldl(fun([_Key, Value], Acc) -> sum_values(Value, Acc) end, 0, KVs).

sum_values({Props}, 0) ->
    {Props};
sum_values({Props}, {AccProps}) ->
    {sum_objects(lists:sort(Props), lists:sort(AccProps))};
sum_values(Value, Acc) when is_number(Value), is_number(Acc) ->
    Acc + Value;
sum_values(Value, Acc) when is_list(Value), is_list(Acc) ->
    sum_arrays(Acc, Value);
sum_values(Value, Acc) when is_number(Value), is_list(Acc) ->
    sum_arrays(Acc, [Value]);
sum_values(Value, Acc) when is_list(Value), is_number(Acc) ->
    sum_arrays([Acc], Value);
sum_values(_Else, _Acc) ->
    throw({invalid_value, ?SUMERROR}).

sum_objects([{K1, V1} | Rest1], [{K1, V2} | Rest2]) ->
    [{K1, sum_values(V1, V2)} | sum_objects(Rest1, Rest2)];
sum_objects([{K1, V1} | Rest1], [{K2, V2} | Rest2]) when K1 < K2 ->
    [{K1, V1}, {K2, V2} | sum_objects(Rest1, Rest2)];
sum_objects([{K1, V1} | Rest1], [{K2, V2} | Rest2]) when K1 > K2 ->
    [{K2, V2}, {K1, V1} | sum_objects(Rest1, Rest2)];
sum_objects([], Rest) ->
    Rest;
sum_objects(Rest, []) ->
    Rest.

sum_arrays([], []) ->
    [];
sum_arrays([_|_]=Xs, []) ->
    Xs;
sum_arrays([], [_|_]=Ys) ->
    Ys;
sum_arrays([X|Xs], [Y|Ys]) when is_number(X), is_number(Y) ->
    [X+Y | sum_arrays(Xs,Ys)];
sum_arrays(_, _) ->
    throw({invalid_value, ?SUMERROR}).

builtin_stats(_, []) ->
    {[{sum,0}, {count,0}, {min,0}, {max,0}, {sumsqr,0}]};
builtin_stats(_, [[_,First]|Rest]) ->
    Unpacked = lists:foldl(fun([_key, Value], Acc) -> stat_values(Value, Acc) end,
                           build_initial_accumulator(First), Rest),
    pack_stats(Unpacked).

stat_values(Value, Acc) when is_list(Value), is_list(Acc) ->
    lists:zipwith(fun stat_values/2, Value, Acc);
stat_values({PreRed}, Acc) when is_list(PreRed) ->
    stat_values(unpack_stats({PreRed}), Acc);
stat_values(Value, Acc) when is_number(Value) ->
    stat_values({Value, 1, Value, Value, Value*Value}, Acc);
stat_values(Value, Acc) when is_number(Acc) ->
    stat_values(Value, {Acc, 1, Acc, Acc, Acc*Acc});
stat_values(Value, Acc) when is_tuple(Value), is_tuple(Acc) ->
    {Sum0, Cnt0, Min0, Max0, Sqr0} = Value,
    {Sum1, Cnt1, Min1, Max1, Sqr1} = Acc,
    {
      Sum0 + Sum1,
      Cnt0 + Cnt1,
      erlang:min(Min0, Min1),
      erlang:max(Max0, Max1),
      Sqr0 + Sqr1
    };
stat_values(_Else, _Acc) ->
    throw({invalid_value, ?STATERROR}).

build_initial_accumulator(L) when is_list(L) ->
    [build_initial_accumulator(X) || X <- L];
build_initial_accumulator(X) when is_number(X) ->
    {X, 1, X, X, X*X};
build_initial_accumulator({Props}) ->
    unpack_stats({Props});
build_initial_accumulator(Else) ->
    Msg = io_lib:format("non-numeric _stats input: ~w", [Else]),
    throw({invalid_value, iolist_to_binary(Msg)}).

unpack_stats({PreRed}) when is_list(PreRed) ->
    {
      get_number(<<"sum">>, PreRed),
      get_number(<<"count">>, PreRed),
      get_number(<<"min">>, PreRed),
      get_number(<<"max">>, PreRed),
      get_number(<<"sumsqr">>, PreRed)
    }.

pack_stats({Sum, Cnt, Min, Max, Sqr}) ->
    {[{<<"sum">>,Sum}, {<<"count">>,Cnt}, {<<"min">>,Min}, {<<"max">>,Max}, {<<"sumsqr">>,Sqr}]};
pack_stats(Stats) when is_list(Stats) ->
    lists:map(fun pack_stats/1, Stats).

get_number(Key, Props) ->
    case couch_util:get_value(Key, Props) of
    X when is_number(X) ->
        X;
    undefined ->
        Msg = io_lib:format("user _stats input missing required field ~s",
            [Key]),
        throw({invalid_value, iolist_to_binary(Msg)});
    Else ->
        Msg = io_lib:format("non-numeric _stats input received for ~s: ~w",
            [Key, Else]),
        throw({invalid_value, iolist_to_binary(Msg)})
    end.

% use the function stored in ddoc.validate_doc_update to test an update.
validate_doc_update(DDoc, EditDoc, DiskDoc, Ctx, SecObj) ->
    JsonEditDoc = couch_doc:to_json_obj(EditDoc, [revs]),
    JsonDiskDoc = json_doc(DiskDoc),
    case ddoc_prompt(DDoc, [<<"validate_doc_update">>], [JsonEditDoc, JsonDiskDoc, Ctx, SecObj]) of
        1 ->
            ok;
        {[{<<"forbidden">>, Message}]} ->
            throw({forbidden, Message});
        {[{<<"unauthorized">>, Message}]} ->
            throw({unauthorized, Message})
    end.

json_doc(nil) -> null;
json_doc(Doc) ->
    couch_doc:to_json_obj(Doc, [revs]).

filter_view(DDoc, VName, Docs) ->
    JsonDocs = [couch_doc:to_json_obj(Doc, [revs]) || Doc <- Docs],
    [true, Passes] = ddoc_prompt(DDoc, [<<"views">>, VName, <<"map">>], [JsonDocs]),
    {ok, Passes}.

filter_docs(Req, Db, DDoc, FName, Docs) ->
    JsonReq = case Req of
    {json_req, JsonObj} ->
        JsonObj;
    #httpd{} = HttpReq ->
        couch_httpd_external:json_req_obj(HttpReq, Db)
    end,
    JsonDocs = [couch_doc:to_json_obj(Doc, [revs]) || Doc <- Docs],
    [true, Passes] = ddoc_prompt(DDoc, [<<"filters">>, FName],
        [JsonDocs, JsonReq]),
    {ok, Passes}.

ddoc_proc_prompt({Proc, DDocId}, FunPath, Args) ->
    proc_prompt(Proc, [<<"ddoc">>, DDocId, FunPath, Args]).

ddoc_prompt(DDoc, FunPath, Args) ->
    with_ddoc_proc(DDoc, fun({Proc, DDocId}) ->
        proc_prompt(Proc, [<<"ddoc">>, DDocId, FunPath, Args])
    end).

with_ddoc_proc(#doc{id=DDocId,revs={Start, [DiskRev|_]}}=DDoc, Fun) ->
    Rev = couch_doc:rev_to_str({Start, DiskRev}),
    DDocKey = {DDocId, Rev},
    Proc = get_ddoc_process(DDoc, DDocKey),
    try Fun({Proc, DDocId})
    after
        ok = ret_os_process(Proc)
    end.

proc_prompt(Proc, Args) ->
     case proc_prompt_raw(Proc, Args) of
     {json, Json} ->
         ?JSON_DECODE(Json);
     EJson ->
         EJson
     end.

proc_prompt_raw(#proc{prompt_fun = {Mod, Func}} = Proc, Args) ->
    apply(Mod, Func, [Proc#proc.pid, Args]).

raw_to_ejson({json, Json}) ->
    ?JSON_DECODE(Json);
raw_to_ejson(EJson) ->
    EJson.

proc_stop(Proc) ->
    {Mod, Func} = Proc#proc.stop_fun,
    apply(Mod, Func, [Proc#proc.pid]).

proc_set_timeout(Proc, Timeout) ->
    {Mod, Func} = Proc#proc.set_timeout_fun,
    apply(Mod, Func, [Proc#proc.pid, Timeout]).

get_ddoc_process(#doc{} = DDoc, DDocKey) ->
    % remove this case statement
    case gen_server:call(couch_proc_manager, {get_proc, DDoc, DDocKey}, infinity) of
    {ok, Proc, {QueryConfig}} ->
        % process knows the ddoc
        case (catch proc_prompt(Proc, [<<"reset">>, {QueryConfig}])) of
        true ->
            proc_set_timeout(Proc, couch_util:get_value(<<"timeout">>, QueryConfig)),
            Proc;
        _ ->
            catch proc_stop(Proc),
            get_ddoc_process(DDoc, DDocKey)
        end;
    Error ->
        throw(Error)
    end.

get_os_process(Lang) ->
    case gen_server:call(couch_proc_manager, {get_proc, Lang}, infinity) of
    {ok, Proc, {QueryConfig}} ->
        case (catch proc_prompt(Proc, [<<"reset">>, {QueryConfig}])) of
        true ->
            proc_set_timeout(Proc, couch_util:get_value(<<"timeout">>, QueryConfig)),
            Proc;
        _ ->
            catch proc_stop(Proc),
            get_os_process(Lang)
        end;
    Error ->
        throw(Error)
    end.

ret_os_process(Proc) ->
    true = gen_server:call(couch_proc_manager, {ret_proc, Proc}, infinity),
    catch unlink(Proc#proc.pid),
    ok.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

sum_values_test() ->
    ?assertEqual(3, sum_values(1, 2)),
    ?assertEqual([2,4,6], sum_values(1, [1,4,6])),
    ?assertEqual([3,5,7], sum_values([3,2,4], [0,3,3])),
    X = {[{<<"a">>,1}, {<<"b">>,[1,2]}, {<<"c">>, {[{<<"d">>,3}]}}]},
    Y = {[{<<"a">>,2}, {<<"b">>,3}, {<<"c">>, {[{<<"e">>, 5}]}}]},
    Z = {[{<<"a">>,3}, {<<"b">>,[4,2]}, {<<"c">>, {[{<<"d">>,3},{<<"e">>,5}]}}]},
    ?assertEqual(Z, sum_values(X, Y)),
    ?assertEqual(Z, sum_values(Y, X)).

stat_values_test() ->
    ?assertEqual({1, 2, 0, 1, 1}, stat_values(1, 0)),
    ?assertEqual({11, 2, 1, 10, 101}, stat_values(1, 10)),
    ?assertEqual([{9, 2, 2, 7, 53},
                  {14, 2, 3, 11, 130},
                  {18, 2, 5, 13, 194}
                 ], stat_values([2,3,5], [7,11,13])).

-endif.