%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% SIP Route/Record-route headers
%%

-module(ersip_hdr_route).

-export([uri/1,
         is_loose_route/1,
         params/1,
         set_param/3,
         make/1,
         parse/1,
         build/2,
         make_route/1
        ]).

-export_type([route/0]).

-include("ersip_headers.hrl").

%%%===================================================================
%%% Types
%%%===================================================================

-record(route, {display_name :: ersip_nameaddr:display_name(),
                uri          :: ersip_uri:uri(),
                params = []  :: [route_param()]
               }).
-type route()     :: #route{}.
-type route_set() :: ersip_route_set:route_set().
-type route_param() :: {Key :: binary(), Value :: binary()}.
-type parse_result() :: {ok, route_set()}
                      | {error, term()}.

-type maybe_rev_route_set() :: {ok, route_set()}
                             | {error, term()}.
%%%===================================================================
%%% API
%%%===================================================================

-spec uri(route()) -> ersip_uri:uri().
uri(#route{uri = URI}) ->
    URI.

-spec is_loose_route(route()) -> boolean().
is_loose_route(#route{uri = URI}) ->
    URIParams  = ersip_uri:params(URI),
    maps:is_key(lr, URIParams).

-spec params(route()) -> [route_param()].
params(#route{params = P}) ->
    P.

-spec set_param(Key :: binary(), Value :: binary(), route()) -> route().
set_param(Key, Value, #route{params = Params} = Route)
        when is_binary(Key), is_binary(Value) ->
    Route#route{params = [{Key, Value} | Params]}.

-spec make(iolist()) -> route_set().
make(Binary) ->
    H0 = ersip_hdr:new(?ERSIPH_ROUTE),
    H1 = ersip_hdr:add_value(Binary, H0),
    case parse(H1) of
        {ok, RouteSet} ->
            RouteSet;
        {error, _} = Error  ->
            error(Error)
    end.

-spec parse(ersip_hdr:header()) -> parse_result().
parse(Header) ->
    MaybeRevRouteSet =
        lists:foldl(fun(IORoute, Acc) ->
                            add_to_maybe_route_set(iolist_to_binary(IORoute), Acc)
                    end,
                    {ok, ersip_route_set:new()},
                    ersip_hdr:raw_values(Header)),
    case MaybeRevRouteSet of
        {ok, RevRouteSet} ->
            {ok, ersip_route_set:reverse(RevRouteSet)};
        {error, Reason} ->
            {error, {invalid_route, Reason}}
    end.


-spec build(HeaderName :: binary(), route_set()) -> ersip_hdr:header().
build(HdrName, {route_set, _} = RouteSet) ->
    Hdr = ersip_hdr:new(HdrName),
    ersip_route_set:foldl(
      fun(Route, HdrAcc) ->
              ersip_hdr:add_value(assemble_route(Route), HdrAcc)
      end,
      Hdr,
      RouteSet).

-spec make_route(binary() | ersip_uri:uri()) -> route().
make_route(Bin) when is_binary(Bin) ->
    case parse_route(Bin) of
        {ok, Route, <<>>} ->
            Route;
        {ok, _, Rest} ->
            error({garbage_at_end, Rest});
        {error, _} = Error ->
            error(Error)
    end;
make_route(URI) ->
    #route{display_name = {display_name, []}, uri = URI}.

%%%===================================================================
%%% Helpers
%%%===================================================================

-spec add_to_maybe_route_set(binary(), maybe_rev_route_set()) -> maybe_rev_route_set().
add_to_maybe_route_set(_, {error, _} = Error) ->
    Error;
add_to_maybe_route_set(Bin, {ok, RouteSet}) ->
    case parse_route(Bin) of
        {ok, Route, <<>>} ->
            {ok, ersip_route_set:add_first(Route, RouteSet)};
        {ok, Route, <<$,, Rest/binary>>} ->
            MaybeRoute = {ok, ersip_route_set:add_first(Route, RouteSet)},
            add_to_maybe_route_set(ersip_bin:trim_head_lws(Rest), MaybeRoute);
        {ok, _, Rest} ->
            {error, {garbage_at_end, Rest}};
        {error, _} = Error ->
            Error
    end.

-spec parse_route(binary()) -> {ok, route(), binary()} | {error, term()}.
parse_route(Bin) ->
    Parsers = [fun ersip_nameaddr:parse/1,
               fun ersip_parser_aux:trim_lws/1,
               fun parse_route_params/1,
               fun ersip_parser_aux:trim_lws/1
              ],
    case ersip_parser_aux:parse_all(Bin, Parsers) of
        {ok, [{DisplayName, URI}, _, ParamsList, _], Rest} ->
            {ok,
             #route{display_name = DisplayName,
                    uri          = URI,
                    params       = ParamsList
                   },
             Rest
            };
        {error, _} = Error ->
            Error
    end.


-spec assemble_route(route()) -> iolist().
assemble_route(#route{} = Route) ->
    #route{display_name = DN,
           uri = URI,
           params = ParamsList
          } = Route,
    [ersip_nameaddr:assemble(DN, URI),
     lists:map(fun({Key, Value}) when is_binary(Value) ->
                       [<<";">>, Key, <<"=">>, Value];
                  ({Key, novalue})  ->
                       [<<";">>, Key]
               end,
               ParamsList)
    ].

-spec parse_route_params(binary()) -> ersip_parser_aux:parse_result([route_param()]).
parse_route_params(<<$;, Bin/binary>>) ->
    do_parse_route_params(Bin);
parse_route_params(Rest) ->
    {ok, [], Rest}.

-spec do_parse_route_params(binary()) -> ersip_parser_aux:parse_result([route_param()]).
do_parse_route_params(Bin) ->
    case ersip_parser_aux:parse_params($;, Bin) of
        {ok, Params, Rest} ->
            {ok, do_parse_params(Params, []), Rest};
        {error, Reason} ->
            {error, {invalid_parameters, Reason}}
    end.

-spec do_parse_params(ersip_parser_aux:gen_param_list(), [{binary(), binary() | novalue}]) ->
                             [{binary(), binary() | novalue}].
do_parse_params([], Acc) ->
    lists:reverse(Acc);
do_parse_params([{Key, <<>>} | Rest], Acc) ->
    Acc1 = [{Key, novalue} | Acc],
    do_parse_params(Rest, Acc1);
do_parse_params([{Key, Value} | Rest], Acc) ->
    Acc1 = [{Key, Value} | Acc],
    do_parse_params(Rest, Acc1).
