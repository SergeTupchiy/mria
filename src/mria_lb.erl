%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc This server runs on the replicant and periodically checks the
%% status of core nodes in case we need to RPC to one of them.
-module(mria_lb).

-behaviour(gen_server).

%% API
-export([ start_link/0
        , probe/2
        , core_nodes/0
        , join_cluster/1
        , leave_cluster/0
        ]).

%% gen_server callbacks
-export([ init/1
        , terminate/2
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , code_change/3
        ]).

%% Internal exports
-export([ core_node_weight/1
        , lb_callback/0
        ]).

-include_lib("snabbkaffe/include/trace.hrl").
-include("mria_rlog.hrl").

%%================================================================================
%% Type declarations
%%================================================================================

-type core_protocol_versions() :: #{node() => integer()}.

-record(s,
        { core_protocol_versions :: core_protocol_versions()
        , core_nodes :: [node()]
        }).

-type node_info() ::
        #{ running := boolean()
         , whoami := core | replicant | mnesia
         , version := string() | undefined
         , protocol_version := non_neg_integer()
         , db_nodes => [node()]
         , shard_badness => [{mria_rlog:shard(), float()}]
         }.

-define(update, update).
-define(SERVER, ?MODULE).
-define(CORE_DISCOVERY_TIMEOUT, 30000).

%%================================================================================
%% API
%%================================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec probe(node(), mria_rlog:shard()) -> boolean().
probe(Node, Shard) ->
    gen_server:call(?SERVER, {probe, Node, Shard}).

-spec core_nodes() -> [node()].
core_nodes() ->
    gen_server:call(?SERVER, core_nodes, ?CORE_DISCOVERY_TIMEOUT).

join_cluster(Node) ->
    {ok, FD} = file:open(seed_file(), [write]),
    ok = io:format(FD, "~p.", [Node]),
    file:close(FD).

leave_cluster() ->
    case file:delete(seed_file()) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        {error, Err} ->
            error(Err)
    end.

%%================================================================================
%% gen_server callbacks
%%================================================================================

init(_) ->
    process_flag(trap_exit, true),
    logger:set_process_metadata(#{domain => [mria, rlog, lb]}),
    start_timer(),
    mria_membership:monitor(membership, self(), true),
    State = #s{ core_protocol_versions = #{}
              , core_nodes = []
              },
    {ok, State}.

handle_info(?update, St) ->
    start_timer(),
    {noreply, do_update(St)};
handle_info({membership, Event}, St) ->
    case Event of
        {mnesia, down, _Node} -> %% Trigger update immediately when core node goes down
            {noreply, do_update(St)};
        _ ->  %% Everything else is handled via timer
            {noreply, St}
    end;
handle_info(Info, St) ->
    ?unexpected_event_tp(#{info => Info, state => St}),
    {noreply, St}.

handle_cast(Cast, St) ->
    ?unexpected_event_tp(#{cast => Cast, state => St}),
    {noreply, St}.

handle_call({probe, Node, Shard}, _From, St0 = #s{core_protocol_versions = ProtoVSNs}) ->
    LastVSNChecked = maps:get(Node, ProtoVSNs, undefined),
    MyVersion = mria_rlog:get_protocol_version(),
    ProbeResult = mria_lib:rpc_call_nothrow({Node, Shard}, mria_rlog_server, do_probe, [Shard]),
    {Reply, ServerVersion} =
        case ProbeResult of
            {true, MyVersion} ->
                {true, MyVersion};
            {true, CurrentVersion} when CurrentVersion =/= LastVSNChecked ->
                ?tp(warning, "Different Mria version on the core node",
                    #{ my_version     => MyVersion
                     , server_version => CurrentVersion
                     , last_version   => LastVSNChecked
                     , node           => Node
                     }),
                {false, CurrentVersion};
            _ ->
                {false, LastVSNChecked}
        end,
    St = St0#s{core_protocol_versions = ProtoVSNs#{Node => ServerVersion}},
    {reply, Reply, St};
handle_call(core_nodes, _From, St = #s{core_nodes = CoreNodes}) ->
    {reply, CoreNodes, St};
handle_call(Call, From, St) ->
    ?unexpected_event_tp(#{call => Call, from => From, state => St}),
    {reply, {error, {unknown_call, Call}}, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

terminate(_Reason, St) ->
    {ok, St}.

%%================================================================================
%% Internal functions
%%================================================================================

do_update(State = #s{core_nodes = OldCoreNodes}) ->
    DiscoveredNodes = discover_nodes(),
    %% Get information about core nodes:
    {NodeInfo0, _BadNodes} = rpc:multicall( DiscoveredNodes
                                          , ?MODULE, lb_callback, []
                                          , mria_config:lb_timeout()
                                          ),
    NodeInfo1 = [I || I = {_, #{whoami := core, running := true}} <- NodeInfo0],
    NodeInfo = maps:from_list(NodeInfo1),
    %% Find partitions of the core cluster, and if the core cluster is
    %% partitioned choose the best partition to connect to:
    Clusters = find_clusters(NodeInfo),
    maybe_report_netsplit(OldCoreNodes, Clusters),
    {IsChanged, NewCoreNodes} = find_best_cluster(OldCoreNodes, Clusters),
    %% Update shards:
    ShardBadness = shard_badness(maps:with(NewCoreNodes, NodeInfo)),
    maps:map(fun(Shard, {Node, _Badness}) ->
                     mria_status:notify_core_node_up(Shard, Node)
             end,
             ShardBadness),
    [mria_status:notify_core_node_down(Shard)
     || Shard <- mria_schema:shards() -- maps:keys(ShardBadness)],
    %% Notify changes
    IsChanged andalso
        ?tp(info, mria_lb_core_discovery_new_nodes,
            #{ previous_cores => OldCoreNodes
             , returned_cores => NewCoreNodes
             , ignored_nodes => DiscoveredNodes -- NewCoreNodes
             , node => node()
             }),
    DiscoveredReplicants = discover_replicants(NewCoreNodes),
    ping_new_nodes(NewCoreNodes, DiscoveredReplicants),
    State#s{core_nodes = NewCoreNodes}.

%% Find fully connected clusters (i.e. cliques of nodes)
-spec find_clusters(#{node() => node_info()}) -> [[node()]].
find_clusters(NodeInfo) ->
    find_clusters(maps:keys(NodeInfo), NodeInfo, []).

find_clusters([], _NodeInfo, Acc) ->
    Acc;
find_clusters([Node|Rest], NodeInfo, Acc) ->
    #{Node := #{db_nodes := Emanent}} = NodeInfo,
    MutualConnections =
        lists:filter(
          fun(Peer) ->
                  case NodeInfo of
                      #{Peer := #{db_nodes := Incident}} ->
                          lists:member(Node, Incident);
                      _ ->
                          false
                  end
          end,
          Emanent),
    Cluster = lists:usort([Node|MutualConnections]),
    find_clusters(Rest -- MutualConnections, NodeInfo, [Cluster|Acc]).

%% Find the preferred core node for each shard:
-spec shard_badness(#{node() => node_info()}) -> #{mria_rlog:shard() => {node(), Badness}}
              when Badness :: float().
shard_badness(NodeInfo) ->
    maps:fold(
      fun(Node, #{shard_badness := Shards}, Acc) ->
              lists:foldl(
                fun({Shard, Badness}, Acc1) ->
                        maps:update_with(Shard,
                                         fun({_OldNode, OldBadness}) when OldBadness > Badness ->
                                                 {Node, Badness};
                                            (Old) ->
                                                 Old
                                         end,
                                         {Node, Badness},
                                         Acc1)
                end,
                Acc,
                Shards)
      end,
      #{},
      NodeInfo).

start_timer() ->
    Interval = mria_config:lb_poll_interval(),
    erlang:send_after(Interval + rand:uniform(Interval), self(), ?update).

-spec find_best_cluster([node()], [[node()]]) -> {_Changed :: boolean(), [node()]}.
find_best_cluster([], []) ->
    {false, []};
find_best_cluster(_OldNodes, []) ->
    %% Discovery failed:
    {true, []};
find_best_cluster(OldNodes, Clusters) ->
    %% Heuristic: pick the best cluster in case of a split brain:
    [Cluster | _] = lists:sort(fun(Cluster1, Cluster2) ->
                                       cluster_score(OldNodes, Cluster1) >=
                                           cluster_score(OldNodes, Cluster2)
                               end,
                               Clusters),
    IsChanged = OldNodes =/= Cluster,
    {IsChanged, Cluster}.

-spec maybe_report_netsplit([node()], [[node()]]) -> ok.
maybe_report_netsplit(OldNodes, Clusters) ->
    Alarm = mria_lb_divergent_alarm,
    case Clusters of
        [_,_|_] ->
            case get(Alarm) of
                undefined ->
                    put(Alarm, true),
                    ?tp(error, mria_lb_split_brain,
                        #{ previous_cores => OldNodes
                         , clusters => Clusters
                         , node => node()
                         });
                _ ->
                    ok
            end;
        _ ->
            %% All discovered nodes belong to the same cluster (or no clusters found):
            erase(Alarm)
    end,
    ok.

%%================================================================================
%% Internal exports
%%================================================================================

%% This function runs on the core node. TODO: remove in the next release
core_node_weight(Shard) ->
    case whereis(Shard) of
        undefined ->
            undefined;
        _Pid ->
            NAgents = length(mria_status:agents(Shard)),
            %% TODO: Add OLP check
            Load = 1.0 * NAgents,
            %% The return values will be lexicographically sorted. Load will
            %% be distributed evenly between the nodes with the same weight
            %% due to the random term:
            {ok, {Load, rand:uniform(), node()}}
    end.

%% Return a bunch of information about the node. Called via RPC.
-spec lb_callback() -> {node(), node_info()}.
lb_callback() ->
    IsRunning = is_pid(whereis(mria_rlog_sup)),
    Whoami = mria_config:whoami(),
    Version = case application:get_key(mria, vsn) of
                  {ok, Vsn} -> Vsn;
                  undefined -> undefined
              end,
    BasicInfo =
        #{ running => IsRunning
         , version => Version
         , whoami => Whoami
         , protocol_version => mria_rlog:get_protocol_version()
         },
    MoreInfo =
        case Whoami of
            core when IsRunning ->
                Badness = [begin
                               Load = length(mria_status:agents(Shard)) + rand:uniform(),
                               {Shard, Load}
                           end || Shard <- mria_schema:shards()],
                #{ db_nodes => mria_mnesia:db_nodes()
                 , shard_badness => Badness
                 };
            _ ->
                #{}
        end,
    {node(), maps:merge(BasicInfo, MoreInfo)}.

%%================================================================================
%% Internal functions
%%================================================================================

-spec discover_nodes() -> [node()].
discover_nodes() ->
    DiscoveryFun = mria_config:core_node_discovery_callback(),
    case manual_seed() of
        [] ->
            %% Run the discovery algorithm
            DiscoveryFun();
        [Seed] ->
            discover_manually(Seed)
    end.

-spec discover_replicants([node()]) -> [node()].
discover_replicants(CoreNodes) ->
    {Replicants0, _BadNodes} = rpc:multicall( CoreNodes
                                            , mria_membership, replicant_nodelist, []
                                            ),
    lists:usort([Node || Nodes <- Replicants0, is_list(Nodes), Node <- Nodes]).

%% Return the last node that has been explicitly specified via
%% "mria:join" command. It overrides other discovery mechanisms.
-spec manual_seed() -> [node()].
manual_seed() ->
    case file:consult(seed_file()) of
        {ok, [Node]} when is_atom(Node) ->
            [Node];
        {error, enoent} ->
            [];
        _ ->
            logger:critical("~p is corrupt. Delete this file and re-join the node to the cluster. Stopping.",
                            [seed_file()]),
            exit(corrupt_seed)
    end.

%% Return the list of core nodes that belong to the same cluster as
%% the seed node.
-spec discover_manually(node()) -> [node()].
discover_manually(Seed) ->
    try mria_lib:rpc_call(Seed, mria_mnesia, db_nodes, [])
    catch _:_ ->
            [Seed]
    end.

seed_file() ->
    filename:join(mnesia:system_info(directory), "mria_replicant_cluster_seed").

cluster_score(OldNodes, Cluster) ->
    %% First we compare the clusters by the number of nodes that are
    %% already in the cluster.  In case of a tie, we choose a bigger
    %% cluster:
    { lists:foldl(fun(Node, Acc) ->
                          case lists:member(Node, OldNodes) of
                              true -> Acc + 1;
                              false -> Acc
                          end
                  end,
                  0,
                  Cluster)
    , length(Cluster)
    }.

%% Ping all new nodes to update mria_membership state
-spec ping_new_nodes([node()], [node()]) -> ok.
ping_new_nodes(CoreNodes, Replicants) ->
    %% mria_membership:running_core_nodelist/0 is a more reliable source
    %% of previous nodes comparing to the list of core nodes stored in
    %% mria_lb state. mria_lb makes updates periodically, so it can overlook
    %% changes when another (core) node leaves and joins quickly
    %% (within mria_lb update period).
    %% At the same time, mria_membership on a replicant node monitors its
    %% corresponding registered processes on all other nodes, so it will
    %% eventually detect a left node.
    NewCoreNodes = CoreNodes -- mria_membership:running_core_nodelist(),
    NewReplicants = Replicants -- mria_membership:running_replicant_nodelist(),
    ping_nodes(NewCoreNodes ++ NewReplicants).

-spec ping_nodes([node()]) -> ok.
ping_nodes(Nodes) ->
    LocalMember = mria_membership:local_any_member(),
    lists:foreach(
      fun(Node) ->
              mria_membership:ping(Node, LocalMember)
      end, Nodes).

%%================================================================================
%% Unit tests
%%================================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

find_clusters_test_() ->
    [ ?_assertMatch( [[1, 2, 3]]
                   , lists:sort(find_clusters(#{ 1 => #{db_nodes => [1, 2, 3]}
                                               , 2 => #{db_nodes => [2, 1, 3]}
                                               , 3 => #{db_nodes => [2, 3, 1]}
                                               }))
                   )
    , ?_assertMatch( [[1], [2, 3]]
                   , lists:sort(find_clusters(#{ 1 => #{db_nodes => [1, 2, 3]}
                                               , 2 => #{db_nodes => [2, 3]}
                                               , 3 => #{db_nodes => [3, 2]}
                                               }))
                   )
    , ?_assertMatch( [[1, 2, 3], [4, 5], [6]]
                   , lists:sort(find_clusters(#{ 1 => #{db_nodes => [1, 2, 3]}
                                               , 2 => #{db_nodes => [1, 2, 3]}
                                               , 3 => #{db_nodes => [3, 2, 1]}
                                               , 4 => #{db_nodes => [4, 5]}
                                               , 5 => #{db_nodes => [4, 5]}
                                               , 6 => #{db_nodes => [6, 4, 5]}
                                               }))
                   )
    ].

shard_badness_test_() ->
    [ ?_assertMatch( #{foo := {n1, 1}, bar := {n2, 2}}
                   , shard_badness(#{ n1 => #{shard_badness => [{foo, 1}]}
                                    , n2 => #{shard_badness => [{foo, 2}, {bar, 2}]}
                                    })
                   )
    ].

cluster_score_test_() ->
    [ ?_assertMatch({0, 0}, cluster_score([], []))
    , ?_assertMatch({0, 2}, cluster_score([], [1, 2]))
    , ?_assertMatch({2, 3}, cluster_score([1, 2, 4], [1, 2, 3]))
    ].

find_best_cluster_test_() ->
    [ ?_assertMatch({false, []}, find_best_cluster([], []))
    , ?_assertMatch({true, []}, find_best_cluster([1], []))
    , ?_assertMatch({false, [1, 2]}, find_best_cluster([1, 2], [[1, 2]]))
    , ?_assertMatch({true, [1, 2, 3]}, find_best_cluster([1, 2], [[1, 2, 3]]))
    , ?_assertMatch({true, [1, 2]}, find_best_cluster([1, 2, 3], [[1, 2]]))
    , ?_assertMatch({false, [1, 2]}, find_best_cluster([1, 2], [[1, 2], [3, 4, 5], [6, 7]]))
    , ?_assertMatch({true, [6, 7]}, find_best_cluster([6, 7, 8], [[1, 2], [3, 4, 5], [6, 7]]))
    , ?_assertMatch({true, [3, 4, 5]}, find_best_cluster([], [[1, 2], [3, 4, 5]]))
    ].

-endif.
