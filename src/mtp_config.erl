%%%-------------------------------------------------------------------
%%% @author Sergey <me@seriyps.ru>
%%% @copyright (C) 2018, Sergey
%%% @doc
%%% Worker that updates datacenter config and proxy secret from
%%% https://core.telegram.org/getProxySecret
%%% and
%%% https://core.telegram.org/getProxyConfig
%%% @end
%%% Created : 10 Jun 2018 by Sergey <me@seriyps.ru>
%%%-------------------------------------------------------------------
-module(mtp_config).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_downstream_safe/2,
         get_downstream_pool/1,
         get_netloc/1,
         get_netloc_safe/1,
         get_secret/0,
         status/0]).
-export([register_name/2,
         unregister_name/1,
         whereis_name/1,
         send/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type dc_id() :: integer().
-type netloc() :: {inet:ip4_address(), inet:port_number()}.

-define(TAB, ?MODULE).
-define(IPS_KEY(DcId), {id, DcId}).
-define(POOL_KEY(DcId), {pool, DcId}).
-define(IDS_KEY, dc_ids).
-define(SECRET_URL, "https://core.telegram.org/getProxySecret").
-define(CONFIG_URL, "https://core.telegram.org/getProxyConfig").

-define(APP, mtproto_proxy).

-record(state, {tab :: ets:tid(),
                monitors = #{} :: #{pid() => {reference(), dc_id()}},
                timer :: gen_timeout:tout()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_downstream_safe(dc_id(), mtp_down_conn:upstream_opts()) ->
                                 {dc_id(), pid(), mtp_down_conn:handle()}.
get_downstream_safe(DcId, Opts) ->
    case get_downstream_pool(DcId) of
        {ok, Pool} ->
            Downstream = mtp_dc_pool:get(Pool, self(), Opts),
            {DcId, Pool, Downstream};
        not_found ->
            [{?IDS_KEY, L}] = ets:lookup(?TAB, ?IDS_KEY),
            NewDcId = random_choice(L),
            get_downstream_safe(NewDcId, Opts)
    end.

get_downstream_pool(DcId) ->
    Key = ?POOL_KEY(DcId),
    case ets:lookup(?TAB, Key) of
        [] -> not_found;
        [{Key, PoolPid}] ->
            {ok, PoolPid}
    end.

-spec get_netloc_safe(dc_id()) -> {dc_id(), netloc()}.
get_netloc_safe(DcId) ->
    case get_netloc(DcId) of
        {ok, Addr} -> {DcId, Addr};
        not_found ->
            [{?IDS_KEY, L}] = ets:lookup(?TAB, ?IDS_KEY),
            NewDcId = random_choice(L),
            %% Get random DC; it might return 0 and recurse aggain
            get_netloc_safe(NewDcId)
    end.

get_netloc(DcId) ->
    Key = ?IPS_KEY(DcId),
    case ets:lookup(?TAB, Key) of
        [] ->
            not_found;
        [{Key, [{_, _} = IpPort]}] ->
            {ok, IpPort};
        [{Key, L}] ->
            IpPort = random_choice(L),
            {ok, IpPort}
    end.

register_name(DcId, Pid) ->
    case ets:insert_new(?TAB, {?POOL_KEY(DcId), Pid}) of
        true ->
            gen_server:cast(?MODULE, {reg, DcId, Pid}),
            yes;
        false -> no
    end.

unregister_name(DcId) ->
    %% making async monitors is a bad idea..
    Pid = whereis_name(DcId),
    gen_server:cast(?MODULE, {unreg, DcId, Pid}),
    ets:delete(?TAB, ?POOL_KEY(DcId)).

whereis_name(DcId) ->
    case get_downstream_pool(DcId) of
        not_found -> undefined;
        {ok, PoolPid} -> PoolPid
    end.

send(Name, Msg) ->
    whereis_name(Name) ! Msg.


-spec get_secret() -> binary().
get_secret() ->
    [{_, Key}] = ets:lookup(?TAB, key),
    Key.

status() ->
    [{?IDS_KEY, L}] = ets:lookup(?TAB, ?IDS_KEY),
    lists:map(
      fun(DcId) ->
              DcPoolStatus = mtp_dc_pool:status(whereis_name(DcId)),
              DcPoolStatus#{dc_id => DcId}
      end, L).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    Timer = gen_timeout:new(
              #{timeout => {env, ?APP, conf_refresh_interval, 3600},
                unit => second}),
    Tab = ets:new(?TAB, [set,
                         public,
                         named_table,
                         {read_concurrency, true}]),
    State = #state{tab = Tab,
                   timer = Timer},
    update(State, force),
    {ok, State}.

%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.
handle_cast({reg, DcId, Pid}, #state{monitors = Mons} = State) ->
    Ref = erlang:monitor(process, Pid),
    Mons1 = Mons#{Pid => {Ref, DcId}},
    {noreply, State#state{monitors = Mons1}};
handle_cast({unreg, DcId, Pid}, #state{monitors = Mons} = State) ->
    {{Ref, DcId}, Mons1} = maps:take(Pid, Mons),
    erlang:demonitor(Ref, [flush]),
    {noreply, State#state{monitors = Mons1}}.
handle_info(timeout, #state{timer = Timer} =State) ->
    case gen_timeout:is_expired(Timer) of
        true ->
            update(State, soft),
            lager:info("Config updated"),
            Timer1 = gen_timeout:bump(
                       gen_timeout:reset(Timer)),
            {noreply, State#state{timer = Timer1}};
        false ->
            {noreply, State#state{timer = gen_timeout:reset(Timer)}}
    end;
handle_info({'DOWN', MonRef, process, Pid, _Reason}, #state{monitors = Mons} = State) ->
    {{MonRef, DcId}, Mons1} = maps:take(Pid, Mons),
    ets:delete(?TAB, ?POOL_KEY(DcId)),
    {noreply, State#state{monitors = Mons1}}.
terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

update(#state{tab = Tab}, force) ->
    update_ip(),
    update_key(Tab),
    update_config(Tab);
update(State, _) ->
    try update(State, force)
    catch Class:Reason ->
            lager:error(
              "Err updating proxy settings: ~s",
              [lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})])
    end.

update_key(Tab) ->
    {ok, Body} = http_get(?SECRET_URL),
    true = ets:insert(Tab, {key, list_to_binary(Body)}).

update_config(Tab) ->
    {ok, Body} = http_get(?CONFIG_URL),
    Downstreams = parse_config(Body),
    update_downstreams(Downstreams, Tab),
    update_ids(Downstreams, Tab).

parse_config(Body) ->
    Lines = string:lexemes(Body, "\n"),
    ProxyLines = lists:filter(
                   fun("proxy_for " ++ _) -> true;
                      (_) -> false
                   end, Lines),
    [parse_downstream(Line) || Line <- ProxyLines].

parse_downstream(Line) ->
    ["proxy_for",
     DcId,
     IpPort] = string:lexemes(Line, " "),
    [Ip, PortWithTrailer] = string:split(IpPort, ":", trailing),
    Port = list_to_integer(string:trim(PortWithTrailer, trailing, ";")),
    {ok, IpAddr} = inet:parse_ipv4strict_address(Ip),
    {list_to_integer(DcId),
     IpAddr,
     Port}.

update_downstreams(Downstreams, Tab) ->
    ByDc = lists:foldl(
             fun({DcId, Ip, Port}, Acc) ->
                     Netlocs = maps:get(DcId, Acc, []),
                     Acc#{DcId => [{Ip, Port} | Netlocs]}
             end, #{}, Downstreams),
    [true = ets:insert(Tab, {?IPS_KEY(DcId), Netlocs})
     || {DcId, Netlocs} <- maps:to_list(ByDc)],
    lists:foreach(
      fun(DcId) ->
              case get_downstream_pool(DcId) of
                  not_found ->
                      %% process will be registered asynchronously by
                      %% gen_server:start_link({via, ..
                      {ok, _Pid} = mtp_dc_pool_sup:start_pool(DcId);
                  {ok, _} ->
                      ok
              end
      end,
      maps:keys(ByDc)).

update_ids(Downstreams, Tab) ->
    Ids = lists:usort([DcId || {DcId, _, _} <- Downstreams]),
    true = ets:insert(Tab, {?IDS_KEY, Ids}).

update_ip() ->
    case application:get_env(?APP, ip_lookup_services) of
        undefined -> false;
        {ok, URLs} ->
            update_ip(URLs)
    end.

update_ip([Url | Fallbacks]) ->
    try
        {ok, Body} = http_get(Url),
        IpStr= string:trim(Body),
        {ok, _} = inet:parse_ipv4strict_address(IpStr), %assert
        application:set_env(?APP, external_ip, IpStr)
    catch Class:Reason ->
            lager:error("Failed to update IP with ~s service: ~s",
                        [Url, lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason})]),
            update_ip(Fallbacks)
    end;
update_ip([]) ->
    error(ip_lookup_failed).

http_get(Url) ->
    {ok, Vsn} = application:get_key(mtproto_proxy, vsn),
    UserAgent = "MTProtoProxy/" ++ Vsn ++ " (+https://github.com/seriyps/mtproto_proxy)",
    Headers = [{"User-Agent", UserAgent}],
    {ok, {{_, 200, _}, _, Body}} =
        httpc:request(get, {Url, Headers}, [{timeout, 3000}], []),
    {ok, Body}.


random_choice(L) ->
    Idx = rand:uniform(length(L)),
    lists:nth(Idx, L).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_test() ->
    Config = ("# force_probability 1 10
proxy_for 1 149.154.175.50:8888;
proxy_for -1 149.154.175.50:8888;
proxy_for 2 149.154.162.39:80;
proxy_for 2 149.154.162.33:80;"),
    Expect = [{1, {149, 154, 175, 50}, 8888},
              {-1, {149, 154, 175, 50}, 8888},
              {2, {149, 154, 162, 39}, 80},
              {2, {149, 154, 162, 33},80}],
    ?assertEqual(Expect, parse_config(Config)).

-endif.
