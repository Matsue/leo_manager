%%======================================================================
%%
%% Leo Manager
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% Leo Manager - API
%% @doc
%% @end
%%======================================================================
-module(leo_manager_api).

-author('Yosuke Hara').

-include("leo_manager.hrl").
-include_lib("leo_commons/include/leo_commons.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("leo_s3_libs/include/leo_s3_bucket.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(API_STORAGE, leo_storage_api).
-define(API_GATEWAY, leo_gateway_api).

-define(TYPE_REBALANCE_TAKEOVER, 'takeover').
-define(TYPE_REBALANCE_REGULAR,  'regular').
-define(type_rebalance(_Ret),
        case _Ret of
            {?TYPE_REBALANCE_TAKEOVER, _} ->
                ?TYPE_REBALANCE_TAKEOVER;
            _ ->
                ?TYPE_REBALANCE_REGULAR
        end).

%% API
-export([load_system_config/0,
         load_system_config_with_store_data/0,
         get_system_config/0, get_system_status/0,
         get_members/0, get_members_of_all_versions/0,
         update_manager_nodes/1,
         get_node_status/1, get_routing_table_chksum/0, get_nodes/0]).

-export([attach/1, attach/4, detach/1, suspend/1, resume/1,
         distribute_members/1, distribute_members/2,
         start/1, rebalance/1]).

-export([register/4, register/7,
         notify/3, notify/4, purge/1, remove/1,
         whereis/2, recover/3, compact/2, compact/4, stats/2,
         synchronize/1, synchronize/2, synchronize/3,
         set_endpoint/1, delete_endpoint/1, delete_bucket/2,
         update_acl/3
        ]).

-export([join_cluster/2, update_cluster_member/2,
         remove_cluster/1]).

-type(system_status() :: ?STATE_RUNNING | ?STATE_STOP).


-record(rebalance_proc_info, {
          members_cur    = [] :: list(#member{}),
          members_prev   = [] :: list(#member{}),
          system_conf    = [] :: list(tuple()),
          rebalance_list = [] :: list()
         }).


%%----------------------------------------------------------------------
%% API-Function(s) - retrieve system information.
%%----------------------------------------------------------------------
%% @doc load a system config file
%%
load_system_config() ->
    {ok, Props} = application:get_env(leo_manager, system),
    SystemConf = #?SYSTEM_CONF{
                     cluster_id = leo_misc:get_value(cluster_id, Props, []),
                     dc_id = leo_misc:get_value(dc_id, Props, []),
                     n = leo_misc:get_value(n, Props, 1),
                     w = leo_misc:get_value(w, Props, 1),
                     r = leo_misc:get_value(r, Props, 1),
                     d = leo_misc:get_value(d, Props, 1),
                     bit_of_ring = leo_misc:get_value(bit_of_ring, Props, 128),
                     num_of_dc_replicas   = leo_misc:get_value(num_of_dc_replicas,   Props, 0),
                     num_of_rack_replicas = leo_misc:get_value(num_of_rack_replicas, Props, 0)
                    },
    SystemConf.


%% @doc load a system config file. a system config file store to mnesia.
%%
-spec(load_system_config_with_store_data() ->
             {ok, #?SYSTEM_CONF{}} | {error, any()}).
load_system_config_with_store_data() ->
    SystemConf = load_system_config(),

    case leo_redundant_manager_tbl_conf:update(SystemConf) of
        ok ->
            #?SYSTEM_CONF{cluster_id = ClusterId,
                          dc_id = DCId,
                          n = N, r = R, w = W, d = D,
                          bit_of_ring = BitOfRing,
                          num_of_dc_replicas = NumOfReplicas,
                          num_of_rack_replicas = NumOfRaclReplicas
                         } = SystemConf,
            case leo_redundant_manager_tbl_cluster_info:update(
                   #cluster_info{cluster_id = ClusterId,
                                 dc_id = DCId,
                                 n = N, r = R, w = W, d = D,
                                 bit_of_ring = BitOfRing,
                                 num_of_dc_replicas = NumOfReplicas,
                                 num_of_rack_replicas = NumOfRaclReplicas}) of
                ok ->
                    {ok, SystemConf};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.


%% @doc Retrieve system configuration from mnesia(localdb).
%%
-spec(get_system_config() ->
             {ok, #?SYSTEM_CONF{}} |
             atom() |
             {error, any()}).
get_system_config() ->
    leo_redundant_manager_tbl_conf:get().


-spec(get_system_status() ->
             system_status() | {error, any()}).
get_system_status() ->
    case leo_manager_mnesia:get_storage_nodes_by_status(?STATE_RUNNING) of
        not_found ->
            ?STATE_STOP;
        {ok, [_H|_]} ->
            ?STATE_RUNNING;
        Error ->
            Error
    end.


%% @doc Retrieve members from mnesia(localdb).
%%
-spec(get_members() ->
             {ok, list()}).
get_members() ->
    leo_redundant_manager_api:get_members().

-spec(get_members_of_all_versions() ->
             {ok, list()}).
get_members_of_all_versions() ->
    case leo_redundant_manager_api:get_members(?VER_CUR) of
        {ok, MembersCur} ->
            case leo_redundant_manager_api:get_members(?VER_PREV) of
                {ok, MembersPrev} ->
                    {ok, {MembersCur, MembersPrev}};
                not_found = Cause ->
                    {error, Cause};
                {error, not_found = Cause} ->
                    {error, Cause};
                {error, Cause} ->
                    ?error("get_members_of_all_versions/0", "cause:~p", [Cause]),
                    {error, Cause}
            end;
        not_found ->
            {error, not_found};
        {error, Cause} ->
            ?error("get_members_of_all_versions/0", "cause:~p", [Cause]),
            {error, Cause}
    end.


%% @doc Retrieve cluster-node-status from each server.
%%
-spec(get_node_status(atom()) ->
             ok | {error, any()}).
get_node_status(Node_1) ->
    Node_2 = list_to_atom(Node_1),
    {Type, Mod} = case leo_manager_mnesia:get_gateway_node_by_name(Node_2) of
                      {ok, _} -> {?SERVER_TYPE_GATEWAY, ?API_GATEWAY};
                      _ ->
                          case leo_manager_mnesia:get_storage_node_by_name(Node_2) of
                              {ok, _} -> {?SERVER_TYPE_STORAGE, ?API_STORAGE};
                              _       -> {[], undefined}
                          end
                  end,

    case Mod of
        undefined ->
            {error, not_found};
        _ ->
            case rpc:call(Node_2, Mod, get_node_status, [], ?DEF_TIMEOUT) of
                {ok, Status} ->
                    {ok, {Type, Status}};
                {_, Cause} ->
                    {error, Cause};
                timeout = Cause ->
                    {error, Cause}
            end
    end.


%% @doc Retrieve ring checksums from redundant-manager.
%%
-spec(get_routing_table_chksum() ->
             {ok, any()} |
             {error, any()}).
get_routing_table_chksum() ->
    case leo_redundant_manager_api:checksum(?CHECKSUM_RING) of
        {ok, []} ->
            {error, ?ERROR_COULD_NOT_GET_CHECKSUM};
        {ok, Chksums} ->
            {ok, Chksums}
    end.


%% @doc Retrieve list of cluster nodes from mnesia.
%%
-spec(get_nodes() ->
             {ok, list()}).
get_nodes() ->
    Nodes_0 = case catch leo_manager_mnesia:get_gateway_nodes_all() of
                  {ok, R1} ->
                      lists:map(fun(#node_state{node  = Node,
                                                state = State}) ->
                                        {gateway, Node, State}
                                end, R1);
                  _ ->
                      []
              end,

    Nodes_1 = case catch leo_manager_mnesia:get_storage_nodes_all() of
                  {ok, R2} ->
                      lists:map(fun(#node_state{node  = Node,
                                                state = State}) ->
                                        {storage, Node, State}
                                end, R2);
                  _Error ->
                      []
              end,
    {ok, Nodes_0 ++ Nodes_1}.


%%----------------------------------------------------------------------
%% API-Function(s) - Operate for the Cluster nodes.
%%----------------------------------------------------------------------
%% @doc Attach an storage-node into the cluster.
%%
-spec(attach(atom()) ->
             ok | {error, any()}).
attach(Node) ->
    attach(Node, [], [], ?DEF_NUMBER_OF_VNODES).

attach(Node,_L1, L2, NumOfVNodes) ->
    case leo_misc:node_existence(Node) of
        true ->
            Status = get_system_status(),
            attach_1(Status, Node,_L1, L2, leo_date:clock(), NumOfVNodes);
        false ->
            {error, ?ERROR_COULD_NOT_CONNECT}
    end.

attach_1(?STATE_RUNNING, Node,_L1, L2, Clock, NumOfVNodes) ->
    State = ?STATE_ATTACHED,
    case leo_redundant_manager_api:reserve(Node, State, L2, Clock, NumOfVNodes) of
        ok ->
            leo_manager_mnesia:update_storage_node_status(
              #node_state{node    = Node,
                          state   = State,
                          when_is = leo_date:now()});
        Error ->
            Error
    end;

attach_1(_, Node,_L1, L2, Clock, NumOfVNodes) ->
    case leo_redundant_manager_api:attach(Node, L2, Clock, NumOfVNodes) of
        ok ->
            leo_manager_mnesia:update_storage_node_status(
              #node_state{node    = Node,
                          state   = ?STATE_ATTACHED,
                          when_is = leo_date:now()});
        {error,_Cause} ->
            {error, ?ERROR_COULD_NOT_ATTACH_NODE}
    end.


%% @doc Suspend a node.
%%
-spec(suspend(string()) ->
             ok | {error, any()}).
suspend(Node) ->
    case leo_redundant_manager_api:has_member(Node) of
        true ->
            case leo_misc:node_existence(Node) of
                true ->
                    case leo_manager_mnesia:update_storage_node_status(
                           update_state, #node_state{node  = Node,
                                                     state = ?STATE_SUSPEND,
                                                     when_is = leo_date:now()
                                                    }) of
                        ok ->
                            Res = leo_redundant_manager_api:suspend(Node),
                            distribute_members(Res, []);
                        {error,_Cause} ->
                            {error, ?ERROR_COULD_NOT_UPDATE_NODE}
                    end;
                false ->
                    {error, ?ERROR_COULD_NOT_CONNECT}
            end;
        false ->
            {error, ?ERROR_NODE_NOT_EXISTS}
    end.


%% @doc Remove a storage-node from the cluster.
%%
-spec(detach(string()) ->
             ok | {error, any()}).
detach(Node) ->
    case leo_redundant_manager_api:has_member(Node) of
        true ->
            State = ?STATE_DETACHED,
            case leo_redundant_manager_api:reserve(
                   Node, State, leo_date:clock()) of
                ok ->
                    case leo_manager_mnesia:update_storage_node_status(
                           #node_state{node    = Node,
                                       state   = State,
                                       when_is = leo_date:now()}) of
                        ok ->
                            ok;
                        {error, _Cause} ->
                            {error, ?ERROR_COULD_NOT_UPDATE_NODE}
                    end;
                {error,_Cause} ->
                    {error, ?ERROR_COULD_NOT_DETACH_NODE}
            end;
        false ->
            {error, ?ERROR_NODE_NOT_EXISTS}
    end.


%% @doc Resume a storage-node when its status is 'RUNNING' OR 'DOWNED'.
%%
-spec(resume(atom()) ->
             ok | {error, any()}).
resume(Node) ->
    case leo_redundant_manager_api:has_member(Node) of
        true ->
            Res = leo_misc:node_existence(Node),
            resume(is_alive, Res, Node);
        false ->
            {error, ?ERROR_NODE_NOT_EXISTS}
    end.


-spec(resume(is_alive | is_state | sync | distribute | last, any(), atom()) ->
             any() | {error, any()}).
resume(is_alive, false, _Node) ->
    {error, ?ERROR_COULD_NOT_CONNECT};
resume(is_alive, true,  Node) ->
    Res = leo_manager_mnesia:get_storage_node_by_name(Node),
    resume(is_state, Res, Node);


resume(is_state, {ok, [#node_state{state = State}|_]}, Node) when State == ?STATE_SUSPEND;
                                                                  State == ?STATE_RESTARTED ->
    Res = leo_redundant_manager_api:update_member_by_node(Node, ?STATE_RUNNING),
    resume(sync, Res, Node);
resume(is_state, {ok, [#node_state{state = State}|_]},_Node) ->
    {error, atom_to_list(State)};
resume(is_state,_Error, _Node) ->
    {error, ?ERROR_COULD_NOT_RESUME_NODE};


resume(sync, ok, Node) ->
    Res = case leo_redundant_manager_api:get_members(?VER_CUR) of
              {ok, MembersCur} ->
                  case leo_redundant_manager_api:get_members(?VER_PREV) of
                      {ok, MembersPrev} ->
                          synchronize(?CHECKSUM_RING, Node, [{?VER_CUR,  MembersCur },
                                                             {?VER_PREV, MembersPrev}]);
                      not_found ->
                          {error, ?ERROR_MEMBER_NOT_FOUND};
                      {error,_Cause} ->
                          {error, ?ERROR_COULD_NOT_GET_MEMBER}
                  end;
              not_found ->
                  {error, ?ERROR_MEMBER_NOT_FOUND};
              {error,_Cause} ->
                  {error, ?ERROR_COULD_NOT_GET_MEMBER}
          end,
    case distribute_members(Res, Node) of
        ok ->
            resume(last, Res, Node);
        Reason ->
            Reason
    end;
resume(sync,_Error, _Node) ->
    {error, ?ERROR_COULD_NOT_RESUME_NODE};

resume(last, ok, Node) ->
    leo_manager_mnesia:update_storage_node_status(
      #node_state{node = Node,
                  state = ?STATE_RUNNING,
                  when_is = leo_date:now()});
resume(last,_Error, _) ->
    {error, ?ERROR_COULD_NOT_RESUME_NODE}.


%% @doc Distribute members list to all nodes.
%% @private
distribute_members([]) ->
    ok;
distribute_members([_|_]= Nodes) ->
    %% Retrieve storage-nodes from mnesia
    case leo_redundant_manager_api:get_members() of
        {ok, Members} ->
            StorageNodes = lists:filter(
                             fun(N) ->
                                     lists:member(N, Nodes) /= true
                             end,  [_N || #member{node  = _N,
                                                  state = ?STATE_RUNNING} <- Members]),

            %% Retrieve gateway nodes, then merge them with storage-nodes
            %% they're destination nodes in order to update "members"
            DestNodes = case leo_manager_mnesia:get_gateway_nodes_all() of
                            {ok, List} ->
                                lists:merge(StorageNodes,
                                            [_N || #member{node  = _N,
                                                           state = ?STATE_RUNNING} <- List]);
                            _ ->
                                StorageNodes
                        end,

            case rpc:multicall(DestNodes, leo_redundant_manager_api, update_members,
                               [Members], ?DEF_TIMEOUT) of
                {_, []} -> void;
                {_, BadNodes} ->
                    ?error("distribute_members/2", "bad-nodes:~p", [BadNodes])
            end,
            ok;
        not_found ->
            {error, ?ERROR_MEMBER_NOT_FOUND};
        {error,_Cause} ->
            {error, ?ERROR_COULD_NOT_GET_MEMBER}
    end;

distribute_members(Node) when is_atom(Node) ->
    distribute_members(ok, Node).

-spec(distribute_members(ok, atom()) ->
             ok | {error, any()}).
distribute_members(ok, Node) ->
    distribute_members([Node]);
distribute_members(_Error, _Node) ->
    {error, ?ERROR_COULD_NOT_GET_MEMBER}.


%% @doc update manager nodes
%%
-spec(update_manager_nodes(list()) ->
             ok | {error, any()}).
update_manager_nodes(Managers) ->
    Ret = case leo_manager_mnesia:get_storage_nodes_all() of
              {ok, Members} ->
                  StorageNodes = [_N || #node_state{node = _N} <- Members],
                  case rpc:multicall(StorageNodes, leo_storage_api, update_manager_nodes,
                                     [Managers], ?DEF_TIMEOUT) of
                      {_, []} -> ok;
                      {_, BadNodes} ->
                          ?error("update_manager_nodes/1", "bad-nodes:~p", [BadNodes]),
                          {error, BadNodes}
                  end;
              _ ->
                  {error, ?ERROR_COULD_NOT_GET_MEMBER}
          end,
    update_manager_nodes(Managers, Ret).

update_manager_nodes(Managers, ok) ->
    case leo_manager_mnesia:get_gateway_nodes_all() of
        {ok, Members} ->
            Fun = fun(#node_state{node  = Node}, Acc) ->
                          [Node|Acc]
                  end,
            GatewayNodes = lists:foldl(Fun, [], Members),
            case rpc:multicall(GatewayNodes, leo_gateway_api, update_manager_nodes,
                               [Managers], ?DEF_TIMEOUT) of
                {_, []} -> ok;
                {_, BadNodes} ->
                    ?error("update_manager_nodes/2", "bad-nodes:~p", [BadNodes]),
                    {error, BadNodes}
            end;
        Error ->
            Error
    end;
update_manager_nodes(_Managers,_Error) ->
    {error, ?ERROR_COULD_NOT_UPDATE_MANAGER}.


%% @doc Launch the leo-storage, but exclude Gateway(s).
%%
-spec(start(port()) ->
             ok | {error, any()}).
start(Socket) ->
    %% Create current and previous RING(routing-table)
    ok = output_message_to_console(Socket, <<"Generating RING...">>),

    case leo_redundant_manager_api:create() of
        {ok, Members, _Chksums} ->
            ok = output_message_to_console(Socket, <<"Generated RING">>),

            %% Retrieve system-configuration
            %% Then launch storage-cluster
            Nodes = [N || #member{node = N} <- Members],

            case leo_redundant_manager_tbl_conf:get() of
                {ok, SystemConf} ->
                    ok = start_1(self(), Nodes, Members, SystemConf),
                    start_2(Socket, 0, length(Members));
                {error, Cause} ->
                    ?error("start/1", "cause:~p", [Cause]),
                    {error, ?ERROR_COULD_NOT_GET_CONF}
            end;
        {error, Cause} ->
            ?error("start/1", "cause:~p", [Cause]),
            {error, ?ERROR_COULD_NOT_CREATE_RING}
    end.


%% @doc Check results and update an object of node-status
%% @private
start_1(_,[],_,_) ->
    ok;
start_1(Pid, [Node|Rest], Members, SystemConf) ->
    spawn(
      fun() ->
              timer:sleep(erlang:phash2(leo_date:clock(), ?DEF_PROC_INTERVAL)),
              Reply = case rpc:call(Node, ?API_STORAGE, start,
                                    [Members, Members, SystemConf], ?DEF_TIMEOUT) of
                          {ok, Ret} ->
                              {ok, Ret};
                          {error, Ret} ->
                              {error, Ret};
                          {_, Cause} ->
                              {error, {Node, Cause}};
                          timeout = Cause ->
                              {error, {Node, Cause}}
                      end,
              erlang:send(Pid, Reply)
      end),
    start_1(Pid, Rest, Members, SystemConf).


%% @doc Check results and update an object of node-status
%% @private
start_2(_Socket, TotalMembers, TotalMembers) ->
    ok;
start_2(Socket, NumOfNodes, TotalMembers) ->
    receive
        Msg ->
            {Node_1, State} =
                case Msg of
                    {ok, {Node, {RingHashCur, RingHashPrev}}} ->
                        leo_manager_mnesia:update_storage_node_status(
                          update,
                          #node_state{node          = Node,
                                      state         = ?STATE_RUNNING,
                                      ring_hash_new = leo_hex:integer_to_hex(RingHashCur,  8),
                                      ring_hash_old = leo_hex:integer_to_hex(RingHashPrev, 8),
                                      when_is       = leo_date:now()}),
                        {Node, <<"OK">>};
                    {error, {Node, Cause}} ->
                        ?error("start_2/3", "node:~w, cause:~p", [Node, Cause]),
                        leo_manager_mnesia:update_storage_node_status(
                          update,
                          #node_state{node    = Node,
                                      state   = ?STATE_STOP,
                                      when_is = leo_date:now()}),
                        {Node, <<"ERROR">>}
                end,

            NewNumOfNodes = NumOfNodes + 1,
            Ratio   = lists:append([integer_to_list(round((NewNumOfNodes / TotalMembers) * 100)), "%"]),
            SendMsg = lists:append([string:right(Ratio, 5), " - ", atom_to_list(Node_1)]),
            ok = output_message_to_console(Socket, State, list_to_binary(SendMsg)),
            start_2(Socket, NewNumOfNodes, TotalMembers)
    after
        infinity ->
            ok
    end.


%% Output a message to the console
%% @private

output_message_to_console(null,_MsgBin) ->
    ok;
output_message_to_console(Socket, MsgBin) ->
    ok = gen_tcp:send(Socket, << MsgBin/binary, "\r\n" >>).

-spec(output_message_to_console(port()|[], binary(), binary()) ->
             ok).
output_message_to_console(null, _State,_MsgBin) ->
    ok;
output_message_to_console(Socket, State, MsgBin) ->
    ok = gen_tcp:send(Socket, << State/binary, MsgBin/binary, "\r\n" >>).


%% @doc Do Rebalance which affect all storage-nodes in operation.
%% [process flow]
%%     1. Judge that "is exist attach-node OR detach-node" ?
%%     2. Distribute every storage node from manager
%%     3. Confirm callback.
%%
-spec(rebalance(port()|null) ->
             ok | {error, any()}).
rebalance(Socket) ->
    case leo_redundant_manager_api:get_members(?VER_CUR) of
        {ok, Members_1} ->
            ok = output_message_to_console(
                   Socket, <<"Generating rebalance-list...">>),
            {State, Nodes} =
                lists:foldl(
                  fun(#member{state = ?STATE_RUNNING },{false, AccN}) ->
                          {true, AccN};
                     (#member{node  = Node,
                              state = ?STATE_ATTACHED},{SoFar, AccN}) ->
                          NS = {?STATE_ATTACHED, Node},
                          {SoFar, [NS|AccN]};
                     (#member{node  = Node,
                              state = ?STATE_DETACHED},{SoFar, AccN}) ->
                          NS = {?STATE_DETACHED, Node},
                          {SoFar, [NS|AccN]};
                     (_Member, SoFar) ->
                          SoFar
                  end, {false, []}, Members_1),

            case rebalance_1(State, Nodes) of
                {ok, RetRebalance} ->
                    ok = output_message_to_console(
                           Socket, <<"Generated rebalance-list">>),

                    case get_members_of_all_versions() of
                        {ok, {MembersCur, MembersPrev}} ->
                            {ok, SystemConf}  = leo_redundant_manager_tbl_conf:get(),
                            RebalanceProcInfo = #rebalance_proc_info{members_cur    = MembersCur,
                                                                     members_prev   = MembersPrev,
                                                                     system_conf    = SystemConf,
                                                                     rebalance_list = RetRebalance},
                            case rebalance_3(Nodes, RebalanceProcInfo) of
                                ok ->
                                    ok = output_message_to_console(
                                           Socket, <<"Distributing rebalance-list to the storage nodes">>),
                                    ok = rebalance_4(self(), MembersCur, RebalanceProcInfo),
                                    rebalance_4_loop(Socket, 0, length(MembersCur));
                                {error, Cause}->
                                    {error, Cause}
                            end;
                        {error,_Cause} ->
                            {error, ?ERROR_COULD_NOT_GET_MEMBER}
                    end;
                {error, Cause} ->
                    {error, Cause}
            end;
        not_found ->
            {error, ?ERROR_MEMBER_NOT_FOUND};
        {error, Cause} ->
            ?error("rebalance/0", "cause:~p", [Cause]),
            {error, ?ERROR_COULD_NOT_GET_MEMBER}
    end.

%% @private
rebalance_1(false,_Nodes) ->
    {error, ?ERROR_NOT_STARTED};
rebalance_1(_State, []) ->
    {error, ?ERROR_NOT_NEED_REBALANCE};
rebalance_1(true, Nodes) ->
    case assign_nodes_to_ring(Nodes) of
        ok ->
            case is_allow_to_distribute_command() of
                {true, _} ->
                    case leo_redundant_manager_api:rebalance() of
                        {ok, List} ->
                            Tbl = leo_hashtable:new(),
                            rebalance_2(Tbl, List);
                        {error, Cause} ->
                            ?error("rebalance_1/2", "cause:~p", [Cause]),
                            {error, ?ERROR_FAIL_REBALANCE}
                    end;
                {false, _} ->
                    {error, ?ERROR_NOT_SATISFY_CONDITION}
            end;
        {error, Cause} ->
            ?error("rebalance_1/2", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_ASSIGN_NODE}
    end.

%% @private
rebalance_2(Tbl, []) ->
    Ret = case leo_hashtable:all(Tbl) of
              []   -> {error, no_entry};
              List -> {ok, List}
          end,
    catch leo_hashtable:destroy(Tbl),
    Ret;
rebalance_2(Tbl, [Item|T]) ->
    %% Item: [{vnode_id, VNodeId0}, {src, SrcNode}, {dest, DestNode}]
    VNodeId  = leo_misc:get_value('vnode_id', Item),
    SrcNode  = leo_misc:get_value('src',      Item),
    DestNode = leo_misc:get_value('dest',     Item),

    case SrcNode of
        {error, no_entry} ->
            void;
        _ ->
            ok = leo_hashtable:append(Tbl, SrcNode, {VNodeId, DestNode})
    end,
    rebalance_2(Tbl, T).

%% @private
rebalance_3([], _RebalanceProcInfo) ->
    ok;
rebalance_3([{?STATE_ATTACHED, Node}|Rest],
            #rebalance_proc_info{members_cur  = MembersCur,
                                 members_prev = MembersPrev,
                                 system_conf  = SystemConf} = RebalanceProcInfo) ->
    %% Send a launch-message to new storage node
    Ret = case rpc:call(Node, ?API_STORAGE, start,
                        [MembersCur, MembersPrev, SystemConf], ?DEF_TIMEOUT) of
              {ok, {_Node, {RingHashCur, RingHashPrev}}} ->
                  case leo_manager_mnesia:update_storage_node_status(
                         update, #node_state{node          = Node,
                                             state         = ?STATE_RUNNING,
                                             ring_hash_new = leo_hex:integer_to_hex(RingHashCur,  8),
                                             ring_hash_old = leo_hex:integer_to_hex(RingHashPrev, 8),
                                             when_is       = leo_date:now()}) of
                      ok ->
                          case leo_redundant_manager_api:update_member_by_node(
                                 Node, ?STATE_RUNNING) of
                              ok ->
                                  ok;
                              Error ->
                                  Error
                          end;
                      Error ->
                          Error
                  end;
              {error, {_Node, Cause}} ->
                  {error, Cause};
              {_, Cause} ->
                  {error, Cause};
              timeout = Cause ->
                  {error, Cause}
          end,

    %% %% Check that fail sending message
    case Ret of
        ok -> void;
        {error, Reason} ->
            ?error("rebalance_3/2", "cause:~p", [Reason])
    end,
    rebalance_3(Rest, RebalanceProcInfo);

rebalance_3([{?STATE_DETACHED, Node}|Rest], RebalanceProcInfo) ->
    case leo_manager_mnesia:get_storage_node_by_name(Node) of
        {ok, [NodeInfo|_]} ->
            _ = leo_manager_mnesia:delete_storage_node(NodeInfo),
            rebalance_3(Rest, RebalanceProcInfo);
        {error, Cause} ->
            ?error("rebalance_3/2", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_REMOVE_NODE}
    end.

%% @private
rebalance_4(_Pid, [],_) ->
    ok;
rebalance_4( Pid, [#member{node  = Node,
                           state = ?STATE_RUNNING}|T], RebalanceProcInfo) ->
    MembersCur    = RebalanceProcInfo#rebalance_proc_info.members_cur,
    MembersPrev   = RebalanceProcInfo#rebalance_proc_info.members_prev,
    RebalanceList = RebalanceProcInfo#rebalance_proc_info.rebalance_list,
    RebalanceList_1 = leo_misc:get_value(Node, RebalanceList, []),

    spawn(
      fun() ->
              timer:sleep(erlang:phash2(leo_date:clock(), ?DEF_PROC_INTERVAL)),
              Ret = case catch rpc:call(Node, ?API_STORAGE, rebalance,
                                        [RebalanceList_1, MembersCur, MembersPrev], ?DEF_TIMEOUT) of
                        {ok, Hashes} ->
                            ok = synchronize_2(Node, Hashes),
                            ok;
                        {_, Cause} ->
                            {error, Cause};
                        timeout = Cause ->
                            {error, Cause}
                    end,
              erlang:send(Pid, {Ret, Node, RebalanceList_1})
      end),
    rebalance_4(Pid, T, RebalanceProcInfo);

rebalance_4(Pid, [#member{node = Node}|T], RebalanceProcInfo) ->
    RebalanceList = RebalanceProcInfo#rebalance_proc_info.rebalance_list,
    RebalanceList_1 = leo_misc:get_value(Node, RebalanceList, []),
    erlang:send(Pid, {ok, Node, RebalanceList_1}),
    rebalance_4(Pid, T, RebalanceProcInfo).


%% @doc receive the results of rebalance
%% @private
rebalance_4_loop(_Socket, TotalMembers, TotalMembers) ->
    ok;
rebalance_4_loop(Socket, NumOfNodes, TotalMembers) ->
    receive
        Msg ->
            {Node_1, State} =
                case Msg of
                    {ok, Node, _RebalanceList} ->
                        {Node, <<"OK">>};
                    OtherMsg ->
                        %% Enqueue a message (fail distribution of rebalance-info)
                        {Ret, Node, RebalanceList} = OtherMsg,
                        ok = leo_manager_mq_client:publish(
                               ?QUEUE_ID_FAIL_REBALANCE, Node, RebalanceList),

                        %% Judge the result of rebalance
                        case Ret of
                            pending ->
                                {Node, <<"PENDING">>};
                            {error, Cause} ->
                                ?error("rebalance_4_loop/3", "node:~w, cause:~p", [Node, Cause]),
                                {Node, <<"ERROR">>}
                        end
                end,
            %% output a message
            NewNumOfNodes = NumOfNodes + 1,
            Ratio   = lists:append([integer_to_list(round((NewNumOfNodes / TotalMembers) * 100)), "%"]),
            SendMsg = lists:append([string:right(Ratio, 5), " - ", atom_to_list(Node_1)]),
            ok = output_message_to_console(Socket, State, list_to_binary(SendMsg)),
            rebalance_4_loop(Socket, NewNumOfNodes, TotalMembers)
    after
        infinity ->
            ok
    end.


%% @private
assign_nodes_to_ring([]) ->
    ok;
assign_nodes_to_ring([{?STATE_ATTACHED, Node}|Rest]) ->
    case leo_redundant_manager_api:get_member_by_node(Node) of
        {ok, #member{grp_level_2 = L2,
                     num_of_vnodes = NumOfVNodes}} ->
            case leo_redundant_manager_api:attach(Node, L2, leo_date:clock(), NumOfVNodes) of
                ok ->
                    assign_nodes_to_ring(Rest);
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
assign_nodes_to_ring([{?STATE_DETACHED, Node}|Rest]) ->
    case leo_redundant_manager_api:detach(Node) of
        ok ->
            assign_nodes_to_ring(Rest);
        Error ->
            Error
    end.


%%----------------------------------------------------------------------
%% API-Function(s) - for system maintenance.
%%----------------------------------------------------------------------
%% @doc Register Pid of storage-node and Pid of gateway-node into the manager-monitors.
%%
-spec(register(first | again, pid(), atom(), atom()) ->
             ok).
register(RequestedTimes, Pid, Node, Type) ->
    leo_manager_cluster_monitor:register(RequestedTimes, Pid, Node, Type).

-spec(register(first | again, pid(), atom(), atom(), string(), string(), pos_integer()) ->
             ok).
register(RequestedTimes, Pid, Node, Type, IdL1, IdL2, NumOfVNodes) ->
    leo_manager_cluster_monitor:register(
      RequestedTimes, Pid, Node, Type, IdL1, IdL2, NumOfVNodes).


%% @doc Notified "Synchronized" from cluster-nods.
%%
notify(synchronized,_VNodeId, Node) ->
    synchronize_1(?SYNC_TARGET_RING_PREV, Node);
notify(_,_,_) ->
    {error, ?ERROR_INVALID_ARGS}.


%% @doc Notified "Server Error" from cluster-nods.
%%
notify(error, DownedNode, NotifyNode, ?ERR_TYPE_NODE_DOWN) ->
    Ret1 = notify_1(DownedNode),
    Ret2 = notify_1(NotifyNode),
    {ok, {Ret1, Ret2}};


%% @doc Notified "Rebalance Progress" from cluster-nods.
%%
notify(rebalance, VNodeId, Node, TotalOfObjects) ->
    leo_manager_mnesia:update_rebalance_info(
      #rebalance_info{vnode_id = VNodeId,
                      node     = Node,
                      total_of_objects = TotalOfObjects,
                      when_is  = leo_date:now()});


%% @doc Notified "Server Launch" from cluster-nods.
%%
notify(launched, gateway, Node, Checksums0) ->
    case get_routing_table_chksum() of
        {ok, Checksums1} when Checksums0 == Checksums1 ->
            {RingHashCur, RingHashPrev} = Checksums1,
            leo_manager_mnesia:update_gateway_node(
              #node_state{node          = Node,
                          state         = ?STATE_RUNNING,
                          ring_hash_new = leo_hex:integer_to_hex(RingHashCur,  8),
                          ring_hash_old = leo_hex:integer_to_hex(RingHashPrev, 8),
                          when_is       = leo_date:now()});
        {ok, _} ->
            {error, ?ERR_TYPE_INCONSISTENT_HASH};
        Error ->
            Error
    end;
notify(_,_,_,_) ->
    {error, ?ERROR_INVALID_ARGS}.


%% @private
notify_1(TargetNode) ->
    case leo_manager_mnesia:get_storage_node_by_name(TargetNode) of
        {ok, [#node_state{state = State,
                          error = NumOfErrors}|_]} ->
            case (State == ?STATE_SUSPEND  orelse
                  State == ?STATE_ATTACHED orelse
                  State == ?STATE_DETACHED orelse
                  State == ?STATE_RESTARTED) of
                true ->
                    ok;
                false ->
                    %% STATE_RUNNING | STATE_STOP
                    case leo_misc:node_existence(TargetNode, (10 * 1000)) of
                        true when State == ?STATE_RUNNING ->
                            ok;
                        true when State /= ?STATE_RUNNING ->
                            notify_2(?STATE_RUNNING, TargetNode);
                        false ->
                            notify_1(?STATE_STOP, TargetNode, NumOfErrors)
                    end;
                _ ->
                    {error, ?ERROR_COULD_NOT_UPDATE_NODE}
            end;
        _Error ->
            {error, ?ERROR_COULD_NOT_UPDATE_NODE}
    end.

%% @private
notify_1(?STATE_STOP = State, Node, NumOfErrors) when NumOfErrors >= ?DEF_NUM_OF_ERROR_COUNT ->
    notify_2(State, Node);

%% @private
notify_1(?STATE_STOP, Node,_NumOfErrors) ->
    case leo_manager_mnesia:update_storage_node_status(
           increment_error, #node_state{node = Node}) of
        ok ->
            ok;
        _Error ->
            {error, ?ERROR_COULD_NOT_UPDATE_NODE}
    end.

%% @private
notify_2(?STATE_RUNNING = State, Node) ->
    Ret = case rpc:call(Node, ?API_STORAGE, get_routing_table_chksum, [], ?DEF_TIMEOUT) of
              {ok, {RingHashCur, RingHashPrev}} ->
                  case rpc:call(Node, ?API_STORAGE, register_in_monitor, [again], ?DEF_TIMEOUT) of
                      ok ->
                          leo_manager_mnesia:update_storage_node_status(
                            update, #node_state{node          = Node,
                                                state         = State,
                                                ring_hash_new = leo_hex:integer_to_hex(RingHashCur,  8),
                                                ring_hash_old = leo_hex:integer_to_hex(RingHashPrev, 8),
                                                when_is       = leo_date:now()});
                      {_, Cause} ->
                          {error, Cause}
                  end;
              {_, Cause} ->
                  {error, Cause}
          end,
    notify_3(Ret, ?STATE_RUNNING, Node);

%% @private
notify_2(State, Node) ->
    Ret = leo_manager_mnesia:update_storage_node_status(
            update_state, #node_state{node  = Node,
                                      state = State}),
    notify_3(Ret, State, Node).

%% @private
notify_3(ok, State, Node) ->
    case leo_redundant_manager_api:update_member_by_node(Node, State) of
        ok ->
            case get_nodes() of
                {ok, []} ->
                    ok;
                {ok, Nodes} ->
                    _ = rpc:multicall(Nodes, leo_redundant_manager_api,
                                      update_member_by_node,
                                      [Node, State], ?DEF_TIMEOUT),
                    ok
            end;
        _Error ->
            {error, ?ERROR_COULD_NOT_UPDATE_NODE}
    end;

%% @private
notify_3({error,_Cause},_State,_Node) ->
    {error, ?ERROR_COULD_NOT_UPDATE_NODE}.


%% @doc purge an object.
%%
-spec(purge(string()) -> ok).
purge(Path) ->
    case leo_manager_mnesia:get_gateway_nodes_all() of
        {ok, R1} ->
            Nodes = lists:foldl(fun(#node_state{node  = Node,
                                                state = ?STATE_RUNNING}, Acc) ->
                                        [Node|Acc];
                                   (_, Acc) ->
                                        Acc
                                end, [], R1),
            _ = rpc:multicall(Nodes, ?API_GATEWAY, purge, [Path], ?DEF_TIMEOUT),
            ok;
        _ ->
            {error, ?ERROR_COULD_NOT_GET_GATEWAY}
    end.


%% @doc remove a gateway-node
%%
-spec(remove(atom()) -> ok | {error, any()}).
remove(Node) when is_atom(Node) ->
    remove_3(Node);
remove(Node) ->
    remove_1(Node).

%% @private
remove_1(Node) ->
    case string:tokens(Node, "@") of
        [_, IP] ->
            remove_2(Node, IP);
        _ ->
            {error, ?ERROR_INVALID_ARGS}
    end.

%% @private
remove_2(Node, IP) ->
    case string:tokens(IP, ".") of
        [_,_,_,_] ->
            remove_3(list_to_atom(Node));
        _ ->
            {error, ?ERROR_INVALID_ARGS}
    end.

%% @private
remove_3(Node) ->
    case leo_manager_mnesia:get_gateway_node_by_name(Node) of
        {ok, [#node_state{state = ?STATE_STOP} = NodeState|_]} ->
            remove_4(NodeState);
        {ok, _} ->
            {error, ?ERROR_STILL_RUNNING};
        _ ->
            {error, ?ERROR_INVALID_ARGS}
    end.

%% @private
remove_4(NodeState) ->
    case leo_manager_mnesia:delete_gateway_node(NodeState) of
        ok ->
            ok;
        _Error ->
            {error, ?ERROR_COULD_NOT_GET_GATEWAY}
    end.


%% @doc Retrieve assigned file information.
%%
-spec(whereis(list(), boolean()) ->
             {ok, any()} |
             {error, any()}).
whereis([Key|_], true) ->
    KeyBin = list_to_binary(Key),
    case leo_redundant_manager_api:get_redundancies_by_key(KeyBin) of
        {ok, #redundancies{id = AddrId, nodes = Redundancies}} ->
            whereis_1(AddrId, KeyBin, Redundancies, []);
        _ ->
            {error, ?ERROR_COULD_NOT_GET_RING}
    end;

whereis(_Key, false) ->
    {error, ?ERROR_COULD_NOT_GET_RING};

whereis(_Key, _HasRoutingTable) ->
    {error, ?ERROR_INVALID_ARGS}.

%% @private
whereis_1(_, _, [],Acc) ->
    {ok, lists:reverse(Acc)};

%% @private
whereis_1(AddrId, Key, [RedundantNode|T], Acc) ->
    Node = RedundantNode#redundant_node.node,
    case RedundantNode#redundant_node.available of
        true ->
            NodeStr = atom_to_list(Node),
            RPCKey  = rpc:async_call(Node, leo_storage_handler_object, head, [AddrId, Key]),
            Reply   = case rpc:nb_yield(RPCKey, ?DEF_TIMEOUT) of
                          {value, {ok, #metadata{addr_id   = AddrId,
                                                 dsize     = DSize,
                                                 cnumber   = ChunkedObjs,
                                                 clock     = Clock,
                                                 timestamp = Timestamp,
                                                 checksum  = Checksum,
                                                 del       = DelFlag}}} ->
                              {NodeStr, AddrId, DSize, ChunkedObjs, Clock, Timestamp, Checksum, DelFlag};
                          _ ->
                              {NodeStr, not_found}
                      end,
            whereis_1(AddrId, Key, T, [Reply | Acc]);
        false ->
            whereis_1(AddrId, Key, T, [{atom_to_list(Node), not_found} | Acc])
    end.


%% @doc Recover key/node
%%
-spec(recover(binary(), string(), boolean()) ->
             ok | {error, any()}).
recover(?RECOVER_BY_FILE, Key, true) ->
    Key1 = list_to_binary(Key),
    case leo_redundant_manager_api:get_redundancies_by_key(Key1) of
        {ok, #redundancies{nodes = Redundancies}} ->
            Nodes = [N || #redundant_node{node = N} <- Redundancies],
            case rpc:multicall(Nodes, ?API_STORAGE, synchronize,
                               [Key1, 'error_msg_replicate_data'], ?DEF_TIMEOUT) of
                {_ResL, []} ->
                    ok;
                {_, BadNodes} ->
                    {error, BadNodes}
            end;
        _ ->
            {error, ?ERROR_COULD_NOT_GET_RING}
    end;
recover(?RECOVER_BY_NODE, Node, true) ->
    Node_1 = case is_atom(Node) of
                 true  -> Node;
                 false -> list_to_atom(Node)
             end,
    %% Check the target node and system-state
    case leo_misc:node_existence(Node_1) of
        true ->
            Ret = case leo_redundant_manager_api:get_member_by_node(Node_1) of
                      {ok, #member{state = ?STATE_RUNNING}} -> true;
                      _ -> false
                  end,
            recover_node_1(Ret, Node_1);
        false ->
            {error, ?ERROR_COULD_NOT_CONNECT}
    end;

recover(?RECOVER_BY_RING, Node, true) ->
    Node_1 = case is_atom(Node) of
                 true  -> Node;
                 false -> list_to_atom(Node)
             end,
    case leo_misc:node_existence(Node_1) of
        true ->
            %% Sync target-node's member/ring with manager
            case get_members_of_all_versions() of
                {ok, {MembersCur, MembersPrev}} ->
                    synchronize(?CHECKSUM_RING, Node_1, [{?VER_CUR,  MembersCur },
                                                         {?VER_PREV, MembersPrev}]);
                not_found ->
                    {error, ?ERROR_MEMBER_NOT_FOUND};
                {error,_Cause} ->
                    {error, ?ERROR_COULD_NOT_GET_MEMBER}
            end;
        false ->
            {error, ?ERROR_COULD_NOT_CONNECT}
    end;

recover(_,_,true) ->
    {error, ?ERROR_INVALID_ARGS};
recover(_,_,false) ->
    {error, ?ERROR_COULD_NOT_GET_RING}.


%% @doc Execute recovery of the target node
%%      Check conditions
%% @private
recover_node_1(true, Node) ->
    {Ret, Members} = is_allow_to_distribute_command(Node),
    recover_node_2(Ret, Members, Node);
recover_node_1(false, _) ->
    {error, ?ERROR_TARGET_NODE_NOT_RUNNING}.

%% @doc Execute recovery of the target node
%% @private
recover_node_2(true, Members, Node) ->
    case rpc:multicall(Members, ?API_STORAGE, synchronize,
                       [Node], ?DEF_TIMEOUT) of
        {_RetL, []} ->
            ok;
        {_, BadNodes} ->
            ?warn("recover_node_3/3", "bad_nodes:~p", [BadNodes]),
            {error, BadNodes}
    end;
recover_node_2(false,_,_) ->
    {error, ?ERROR_NOT_SATISFY_CONDITION}.


%% @doc Do compact.
%%
-spec(compact(string(), string() | atom()) ->
             ok).
compact(Mode, Node) when is_list(Node) ->
    compact(Mode, list_to_atom(Node));
compact(Mode, Node) ->
    ModeAtom = case Mode of
                   ?COMPACT_SUSPEND -> suspend;
                   ?COMPACT_RESUME  -> resume;
                   ?COMPACT_STATUS  -> status;
                   _ -> {error, ?ERROR_INVALID_ARGS}
               end,

    case ModeAtom of
        {error, Cause} ->
            {error, Cause};
        _ ->
            case rpc:call(Node, ?API_STORAGE, compact, [ModeAtom], ?DEF_TIMEOUT) of
                ok ->
                    ok;
                {ok, Status} ->
                    {ok, Status};
                {_, Cause} ->
                    ?warn("compact/2", "cause:~p", [Cause]),
                    {error, ?ERROR_FAILED_COMPACTION}
            end
    end.


-spec(compact(atom(), string() | atom(), list(), integer()) ->
             ok | {error, any}).
compact(_, [], _NumOfTargets, _MaxProc) ->
    {error, not_found};
compact(?COMPACT_START, Node, NumOfTargets, MaxProc) when is_list(Node) ->
    compact(?COMPACT_START, list_to_atom(Node), NumOfTargets, MaxProc);
compact(?COMPACT_START, Node, NumOfTargets, MaxProc) ->
    case leo_misc:node_existence(Node) of
        true ->
            case rpc:call(Node, ?API_STORAGE, compact,
                          [start, NumOfTargets, MaxProc], ?DEF_TIMEOUT) of
                ok ->
                    ok;
                {_, Cause} ->
                    ?warn("compact/4", "cause:~p", [Cause]),
                    {error, ?ERROR_FAILED_COMPACTION}
            end;
        false ->
            {error, ?ERR_TYPE_NODE_DOWN}
    end;
compact(_,_,_,_) ->
    {error, ?ERROR_INVALID_ARGS}.


%% @doc get storage stats.
%%
-spec(stats(summary | detail, string() | atom()) ->
             {ok, list()} | {error, any}).
stats(_, []) ->
    {error, not_found};

stats(Mode, Node) when is_list(Node) ->
    stats(Mode, list_to_atom(Node));

stats(Mode, Node) ->
    case leo_manager_mnesia:get_storage_node_by_name(Node) of
        {ok, _} ->
            case leo_misc:node_existence(Node) of
                true ->
                    case rpc:call(Node, leo_object_storage_api, stats, [], ?DEF_TIMEOUT) of
                        not_found = Cause ->
                            {error, Cause};
                        {ok, []} ->
                            {error, not_found};
                        {ok, Result} ->
                            stats1(Mode, Result)
                    end;
                false ->
                    {error, ?ERR_TYPE_NODE_DOWN}
            end;
        _ ->
            {error, ?ERROR_NODE_NOT_EXISTS}
    end.

%% @private
stats1(summary, List) ->
    {ok, lists:foldl(
           fun({ok, #storage_stats{file_path  = _ObjPath,
                                   compaction_histories = Histories,
                                   total_sizes = TotalSize,
                                   active_sizes = ActiveSize,
                                   total_num  = Total,
                                   active_num = Active}},
               {SumTotal, SumActive, SumTotalSize, SumActiveSize, LatestStart, LatestEnd}) ->
                   {LatestStart1, LatestEnd1} =
                       case length(Histories) of
                           0 -> {LatestStart, LatestEnd};
                           _ ->
                               {StartComp, FinishComp} = hd(Histories),
                               {max(LatestStart, StartComp), max(LatestEnd, FinishComp)}
                       end,
                   {SumTotal + Total,
                    SumActive + Active,
                    SumTotalSize + TotalSize,
                    SumActiveSize + ActiveSize,
                    LatestStart1,
                    LatestEnd1};
              (_, Acc) ->
                   Acc
           end, {0, 0, 0, 0, 0, 0}, List)};
stats1(detail, List) ->
    {ok, List}.


%% @doc Synchronize Members and Ring (both New and Old).
%%
synchronize(Type) when Type == ?CHECKSUM_RING;
                       Type == ?CHECKSUM_MEMBER ->
    case leo_redundant_manager_api:get_members(?VER_CUR) of
        {ok, MembersCur} ->
            case leo_redundant_manager_api:get_members(?VER_PREV) of
                {ok, MembersPrev} ->
                    %% synchronize member and ring with remote-node(s)
                    lists:map(
                      fun(#member{node  = Node,
                                  state = ?STATE_RUNNING}) ->
                              synchronize(Type, Node, [{?VER_CUR,  MembersCur },
                                                       {?VER_PREV, MembersPrev}]);
                         (_) ->
                              ok
                      end, MembersCur);
                not_found ->
                    {error, ?ERROR_MEMBER_NOT_FOUND};
                {error,_Cause} ->
                    {error, ?ERROR_COULD_NOT_GET_MEMBER}
            end;
        not_found ->
            {error, ?ERROR_MEMBER_NOT_FOUND};
        {error,_Cause} ->
            {error, ?ERROR_COULD_NOT_GET_MEMBER}
    end;

%% @doc Compare local ring checksum with remote it
%%
synchronize(Node) when is_atom(Node) ->
    case leo_redundant_manager_api:checksum(?CHECKSUM_RING) of
        {ok, {RingHashCur, RingHashPrev}} ->
            case leo_manager_mnesia:get_storage_node_by_name(Node) of
                {ok, [#node_state{ring_hash_new = RingHashCurHex,
                                  ring_hash_old = RingHashPrevHex}|_]} ->
                    RingHashCur_1  = leo_hex:hex_to_integer(RingHashCurHex),
                    RingHashPrev_1 = leo_hex:hex_to_integer(RingHashPrevHex),

                    case (RingHashCur  /= RingHashCur_1 orelse
                          RingHashPrev /= RingHashPrev_1) of
                        true ->
                            synchronize(?CHECKSUM_RING, Node);
                        false ->
                            void
                    end;
                _ ->
                    void
            end;
        _ ->
            void
    end,
    ok;
synchronize(_) ->
    {error, ?ERROR_INVALID_ARGS}.


synchronize(Type, Node, MembersList) when Type == ?CHECKSUM_RING;
                                          Type == ?CHECKSUM_MEMBER ->
    {ok, SystemConf} = leo_redundant_manager_tbl_conf:get(),
    Options = [{cluster_id, SystemConf#?SYSTEM_CONF.cluster_id},
               {dc_id,      SystemConf#?SYSTEM_CONF.dc_id},
               {n, SystemConf#?SYSTEM_CONF.n},
               {r, SystemConf#?SYSTEM_CONF.r},
               {w, SystemConf#?SYSTEM_CONF.w},
               {d, SystemConf#?SYSTEM_CONF.d},
               {bit_of_ring,          SystemConf#?SYSTEM_CONF.bit_of_ring},
               {num_of_dc_replicas,   SystemConf#?SYSTEM_CONF.num_of_dc_replicas},
               {num_of_rack_replicas, SystemConf#?SYSTEM_CONF.num_of_rack_replicas}
              ],
    MembersCur  = leo_misc:get_value(?VER_CUR,  MembersList),
    MembersPrev = leo_misc:get_value(?VER_PREV, MembersList),

    case rpc:call(Node, leo_redundant_manager_api, synchronize,
                  [?SYNC_TARGET_BOTH, [{?VER_CUR,  MembersCur },
                                       {?VER_PREV, MembersPrev}], Options], ?DEF_TIMEOUT) of
        {ok, Hashes} ->
            {RingHashCur, RingHashPrev} = leo_misc:get_value(?CHECKSUM_RING, Hashes),
            leo_manager_mnesia:update_storage_node_status(
              update_chksum, #node_state{node          = Node,
                                         ring_hash_new = leo_hex:integer_to_hex(RingHashCur, 8),
                                         ring_hash_old = leo_hex:integer_to_hex(RingHashPrev,8)}),
            ok;
        not_found ->
            {error, ?ERROR_FAIL_TO_SYNCHRONIZE_RING};
        {_, Cause} ->
            ?warn("synchronize/3", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_SYNCHRONIZE_RING};
        timeout = Cause ->
            ?warn("synchronize/3", "cause:~p", [Cause]),
            {error, Cause}
    end;
synchronize(_,_,_) ->
    ok.

%% @doc From manager-node
synchronize(?CHECKSUM_MEMBER, Node) when is_atom(Node) ->
    synchronize_1(?SYNC_TARGET_MEMBER, Node);

synchronize(?CHECKSUM_RING, Node) when is_atom(Node) ->
    synchronize_1(?SYNC_TARGET_RING_CUR,  Node),
    synchronize_1(?SYNC_TARGET_RING_PREV, Node),
    ok;


%% @doc From gateway and storage-node
synchronize(?CHECKSUM_MEMBER = Type, [{Node_1, Checksum_1},
                                      {Node_2, Checksum_2}]) ->
    Ret = case (Node_1 == node()) of
              true ->
                  case leo_manager_mnesia:get_storage_node_by_name(Node_2) of
                      {ok, [#node_state{state = ?STATE_STOP}|_]} ->
                          notify_1(Node_2);
                      _ ->
                          not_match
                  end;
              false ->
                  not_match
          end,

    case Ret of
        not_match ->
            {ok, LocalChecksum} =
                leo_redundant_manager_api:checksum(Type),
            compare_local_chksum_with_remote_chksum(
              ?SYNC_TARGET_MEMBER, Node_1, LocalChecksum, Checksum_1),
            compare_local_chksum_with_remote_chksum(
              ?SYNC_TARGET_MEMBER, Node_2, LocalChecksum, Checksum_2);
        _ ->
            Ret
    end;

synchronize(?CHECKSUM_RING = Type, [{Node_1, {RingHashCur_1, RingHashPrev_1}},
                                    {Node_2, {RingHashCur_2, RingHashPrev_2}}]) ->
    {ok, {LocalRingHashCur, LocalRingHashPrev}} =
        leo_redundant_manager_api:checksum(Type),

    %% copare manager-cur-ring-hash with remote cur-ring-hash
    _ = compare_local_chksum_with_remote_chksum(
          ?SYNC_TARGET_RING_CUR,  Node_1, LocalRingHashCur,  RingHashCur_1),
    _ = compare_local_chksum_with_remote_chksum(
          ?SYNC_TARGET_RING_CUR,  Node_2, LocalRingHashCur,  RingHashCur_2),

    %% copare manager-cur/prev-ring-hash/ with remote prev-ring-hash
    _ = compare_local_chksum_with_remote_chksum(
          ?SYNC_TARGET_RING_PREV, Node_1, LocalRingHashPrev, RingHashPrev_1),
    _ = compare_local_chksum_with_remote_chksum(
          ?SYNC_TARGET_RING_PREV, Node_2, LocalRingHashPrev, RingHashPrev_2).


%% @doc Synchronize members-list or rings
%% @private
-spec(synchronize_1(?SYNC_TARGET_MEMBER   |
                    ?SYNC_TARGET_RING_CUR |
                    ?SYNC_TARGET_RING_PREV, atom()) ->
             ok | {error, any()}).
synchronize_1(?SYNC_TARGET_MEMBER = Type, Node) ->
    case leo_redundant_manager_api:get_members(?VER_CUR) of
        {ok, MembersCur} ->
            case leo_redundant_manager_api:get_members(?VER_PREV) of
                {ok, MembersPrev} ->
                    case rpc:call(Node, leo_redundant_manager_api, synchronize,
                                  [Type, [{?VER_CUR,  MembersCur},
                                          {?VER_PREV, MembersPrev}]], ?DEF_TIMEOUT) of
                        {ok, _} ->
                            ok;
                        timeout = Cause ->
                            {error, Cause};
                        Error ->
                            Error
                    end;
                not_found ->
                    {error, ?ERROR_MEMBER_NOT_FOUND};
                {error,_Cause} ->
                    {error, ?ERROR_COULD_NOT_GET_MEMBER}
            end;
        not_found ->
            {error, ?ERROR_MEMBER_NOT_FOUND};
        {error,_Cause} ->
            {error, ?ERROR_COULD_NOT_GET_MEMBER}
    end;

synchronize_1(Type, Node) when Type == ?SYNC_TARGET_RING_CUR;
                               Type == ?SYNC_TARGET_RING_PREV ->
    {ok, {L_RingHashCur, L_RingHashPrev}} = leo_redundant_manager_api:checksum(?CHECKSUM_RING),

    case rpc:call(Node, leo_redundant_manager_api, checksum,
                  [?CHECKSUM_RING], ?DEF_TIMEOUT) of
        {ok, {R_RingHashCur, R_RingHashPrev} = Hashes} ->
            ok = synchronize_2(Node, [{?CHECKSUM_RING, Hashes}]),
            CheckHash = case Type of
                            ?SYNC_TARGET_RING_CUR  when L_RingHashCur  == R_RingHashCur  -> true;
                            ?SYNC_TARGET_RING_PREV when L_RingHashPrev == R_RingHashPrev -> true;
                            _ ->
                                false
                        end,

            case CheckHash of
                true  -> ok;
                false ->
                    synchronize_1_1(Type, Node)
            end;
        {_, Cause} ->
            ?error("synchronize_1/2", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_SYNCHRONIZE_RING};
        timeout = Cause ->
            {error, Cause}
    end;
synchronize_1(_,_) ->
    {error, ?ERROR_INVALID_ARGS}.


%% @private
synchronize_1_1(Type, Node) ->
    Ver = case Type of
              ?SYNC_TARGET_RING_CUR  -> ?VER_CUR;
              ?SYNC_TARGET_RING_PREV -> ?VER_PREV
          end,

    case leo_redundant_manager_api:get_members(Ver) of
        {ok, Members} ->
            case rpc:call(Node, leo_redundant_manager_api, synchronize,
                          [Type, [{Ver, Members}]], ?DEF_TIMEOUT) of
                {ok, Hashes} ->
                    synchronize_2(Node, Hashes);
                {_, Cause} ->
                    ?error("synchronize_1/2", "cause:~p", [Cause]),
                    {error, ?ERROR_FAIL_TO_SYNCHRONIZE_RING};
                timeout = Cause ->
                    {error, Cause}
            end;
        not_found ->
            {error, ?ERROR_MEMBER_NOT_FOUND};
        {error,_Cause} ->
            {error, ?ERROR_COULD_NOT_GET_MEMBER}
    end.


synchronize_2(Node, Hashes) ->
    {RingHashCur, RingHashPrev} = leo_misc:get_value(?CHECKSUM_RING, Hashes),

    case leo_manager_mnesia:get_gateway_node_by_name(Node) of
        {ok, [NodeState|_]} ->
            leo_manager_mnesia:update_gateway_node(
              NodeState#node_state{ring_hash_new = leo_hex:integer_to_hex(RingHashCur,  8),
                                   ring_hash_old = leo_hex:integer_to_hex(RingHashPrev, 8)});
        _ ->
            case leo_manager_mnesia:get_storage_node_by_name(Node) of
                {ok, _} ->
                    leo_manager_mnesia:update_storage_node_status(
                      update_chksum,
                      #node_state{node  = Node,
                                  ring_hash_new = leo_hex:integer_to_hex(RingHashCur,  8),
                                  ring_hash_old = leo_hex:integer_to_hex(RingHashPrev, 8)});
                _ ->
                    void
            end
    end,
    ok.


%% @doc Compare local-checksum with remote-checksum
%% @private
compare_local_chksum_with_remote_chksum(_Type,_Node, Checksum_1, Checksum_2)
  when Checksum_1 =:= Checksum_2 -> ok;
compare_local_chksum_with_remote_chksum( Type, Node, Checksum_1, Checksum_2)
  when Checksum_1 =/= Checksum_2 -> synchronize_1(Type, Node).


%% @doc Insert an endpoint
%%
-spec(set_endpoint(binary()) ->
             ok | {error, any()}).
set_endpoint(EndPoint) ->
    case leo_s3_endpoint:set_endpoint(EndPoint) of
        ok ->
            rpc_call_for_gateway(set_endpoint, [EndPoint]);
        {error, Cause} ->
            ?error("set_endpoint/1", "cause:~p", [Cause]),
            {error, ?ERROR_COULD_NOT_SET_ENDPOINT}
    end.


%% @doc Insert an endpoint
%%
-spec(delete_endpoint(binary()) ->
             ok | {error, any()}).
delete_endpoint(EndPoint) ->
    case leo_s3_endpoint:delete_endpoint(EndPoint) of
        ok ->
            rpc_call_for_gateway(delete_endpoint, [EndPoint]);
        {error, Cause} ->
            ?error("delete_endpoint/1", "cause:~p", [Cause]),
            {error, ?ERROR_COULD_NOT_REMOVE_ENDPOINT}
    end.


%% @doc Remove a bucket from storage-cluster and manager
%%
-spec(delete_bucket(binary(), binary()) ->
             ok | {error, any()}).
delete_bucket(AccessKey, Bucket) ->
    AccessKeyBin = case is_binary(AccessKey) of
                       true  -> AccessKey;
                       false -> list_to_binary(AccessKey)
                   end,
    BucketBin    = case is_binary(Bucket) of
                       true  -> Bucket;
                       false -> list_to_binary(Bucket)
                   end,

    %% Check preconditions
    case is_allow_to_distribute_command() of
        {true, _}->
            case leo_s3_bucket:head(AccessKeyBin, BucketBin) of
                ok ->
                    delete_bucket_1(AccessKeyBin, BucketBin);
                not_found ->
                    {error, ?ERROR_BUCKET_NOT_FOUND};
                {error, _} ->
                    {error, ?ERROR_INVALID_ARGS}
            end;
        _ ->
            {error, ?ERROR_NOT_SATISFY_CONDITION}
    end.

delete_bucket_1(AccessKeyBin, BucketBin) ->
    case leo_redundant_manager_api:get_members_by_status(?STATE_RUNNING) of
        {ok, Members} ->
            Nodes = lists:map(fun(#member{node = Node}) ->

                                      Node
                              end, Members),
            case rpc:multicall(Nodes, leo_storage_handler_directory,
                               delete_objects_in_parent_dir,
                               [BucketBin], ?DEF_TIMEOUT) of
                {_, []} -> void;
                {_, BadNodes} ->
                    ?error("delete_bucket_1/2", "bad-nodes:~p", [BadNodes])
            end,
            delete_bucket_2(AccessKeyBin, BucketBin);
        _ ->
            {error, ?ERROR_NOT_STARTED}
    end.

delete_bucket_2(AccessKeyBin, BucketBin) ->
    case leo_s3_bucket:delete(AccessKeyBin, BucketBin) of
        ok ->
            ok;
        {error, badarg} ->
            {error, ?ERROR_INVALID_BUCKET_FORMAT};
        {error, _Cause} ->
            {error, ?ERROR_COULD_NOT_STORE}
    end.


%% @doc Update permission by access-key-id
%%
-spec(update_acl(string(), binary(), binary()) ->
             ok | {error, any()}).
update_acl(?CANNED_ACL_PRIVATE = Permission, AccessKey, Bucket) ->
    case leo_s3_bucket:update_acls2private(AccessKey, Bucket) of
        ok ->
            rpc_call_for_gateway(update_acl, [Permission, AccessKey, Bucket]);
        {error, Cause} ->
            ?error("update_acl/3", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_UPDATE_ACL}
    end;
update_acl(?CANNED_ACL_PUBLIC_READ = Permission, AccessKey, Bucket) ->
    case leo_s3_bucket:update_acls2public_read(AccessKey, Bucket) of
        ok ->
            rpc_call_for_gateway(update_acl, [Permission, AccessKey, Bucket]);
        {error, Cause} ->
            ?error("update_acl/3", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_UPDATE_ACL}
    end;
update_acl(?CANNED_ACL_PUBLIC_READ_WRITE = Permission, AccessKey, Bucket) ->
    case leo_s3_bucket:update_acls2public_read_write(AccessKey, Bucket) of
        ok ->
            rpc_call_for_gateway(update_acl, [Permission, AccessKey, Bucket]);
        {error, Cause} ->
            ?error("update_acl/3", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_UPDATE_ACL}
    end;
update_acl(?CANNED_ACL_AUTHENTICATED_READ = Permission, AccessKey, Bucket) ->
    case leo_s3_bucket:update_acls2authenticated_read(AccessKey, Bucket) of
        ok ->
            rpc_call_for_gateway(update_acl, [Permission, AccessKey, Bucket]);
        {error, Cause} ->
            ?error("update_acl/3", "cause:~p", [Cause]),
            {error, ?ERROR_FAIL_TO_UPDATE_ACL}
    end;
update_acl(_,_,_) ->
    {error, ?ERROR_INVALID_ARGS}.


%% @doc RPC call for Gateway-nodes
%% @private
-spec(rpc_call_for_gateway(atom(), list()) ->
             ok | {error, any()}).
rpc_call_for_gateway(Method, Args) ->
    case catch leo_manager_mnesia:get_gateway_nodes_all() of
        {ok, Nodes_0} ->
            case [Node || #node_state{node  = Node,
                                      state = ?STATE_RUNNING} <- Nodes_0] of
                [] ->
                    ok;
                Nodes_1 ->
                    case rpc:multicall(Nodes_1, ?API_GATEWAY, Method, Args,
                                       ?DEF_TIMEOUT) of
                        {_, []} ->
                            ok;
                        {_, BadNodes} ->
                            {error, BadNodes}
                    end
            end;
        not_found ->
            ok;
        _Error ->
            {error, ?ERROR_COULD_NOT_GET_GATEWAY}
    end.


%% @doc Join a cluster (MDC-Replication)
%%
-spec(join_cluster(list(atom()), #system_conf{}) ->
             {ok, #system_conf{}} | {error, any()}).
join_cluster(RemoteManagerNodes,
             #?SYSTEM_CONF{cluster_id = ClusterId,
                           dc_id = DCId,
                           n = N, r = R, w = W, d = D,
                           bit_of_ring = BitOfRing,
                           num_of_dc_replicas = NumOfReplicas,
                           num_of_rack_replicas = NumOfRaclReplicas
                          }) ->
    %% update cluster info in order to
    %%    communicate with remote-cluster(s)
    case leo_redundant_manager_tbl_cluster_info:get(ClusterId) of
        not_found ->
            case leo_redundant_manager_tbl_cluster_info:update(
                   #cluster_info{cluster_id = ClusterId,
                                 dc_id = DCId,
                                 n = N, r = R, w = W, d = D,
                                 bit_of_ring = BitOfRing,
                                 num_of_dc_replicas = NumOfReplicas,
                                 num_of_rack_replicas = NumOfRaclReplicas}) of
                ok ->
                    %% update info of remote-managers
                    ok = update_cluster_member(RemoteManagerNodes, ClusterId),
                    %% retrieve the system-conf of current cluster
                    leo_redundant_manager_tbl_conf:get();
                Error ->
                    Error
            end;
        {ok,_} ->
            {error, ?ERROR_ALREADY_HAS_SAME_CLUSTER};
        Error ->
            Error
    end.


%% @doc Update cluster members for MDC-replication
%%
-spec(update_cluster_member(list(atom()), atom()) ->
             ok).
update_cluster_member([],_ClusterId) ->
    ok;
update_cluster_member([Node|Rest], ClusterId) ->
    case leo_redundant_manager_tbl_cluster_mgr:update(
           #cluster_manager{node = Node,
                            cluster_id = ClusterId}) of
        ok ->
            update_cluster_member(Rest, ClusterId);
        Other ->
            Other
    end.


%% @doc Remove a cluster (MDC-Replication)
%%
-spec(remove_cluster(#system_conf{}) ->
             {ok, #system_conf{}} | {error, any()}).
remove_cluster(#?SYSTEM_CONF{cluster_id = ClusterId}) ->
    leo_redundant_manager_tbl_cluster_info:delete(ClusterId).


%% @doc Is allow distribute to a command
%% @private
-spec(is_allow_to_distribute_command() ->
             boolean()).
is_allow_to_distribute_command() ->
    is_allow_to_distribute_command([]).

-spec(is_allow_to_distribute_command(atom()) ->
             boolean()).
is_allow_to_distribute_command(Node) ->
    {ok, SystemConf} = leo_redundant_manager_tbl_conf:get(),
    {ok, Members_1}  = leo_redundant_manager_api:get_members(),
    {Total, Active, Members_2} =
        lists:foldl(fun(#member{node = N}, Acc) when N == Node ->
                            Acc;
                       (#member{state = ?STATE_DETACHED}, Acc) ->
                            Acc;
                       (#member{state = ?STATE_ATTACHED}, Acc) ->
                            Acc;
                       (#member{state = ?STATE_RUNNING,
                                node  = N}, {Num1, Num2, M}) ->
                            {Num1+1, Num2+1, [N|M]};
                       (#member{}, {Num1, Num2, M}) ->
                            {Num1+1, Num2, M}
                    end, {0,0,[]}, Members_1),

    NVal = SystemConf#?SYSTEM_CONF.n,
    Diff = case (SystemConf#?SYSTEM_CONF.n < 2) of
               true  -> 0;
               false -> NVal - (NVal - 1)
           end,
    Ret  = ((Total - Active) =< Diff),
    {Ret, Members_2}.
