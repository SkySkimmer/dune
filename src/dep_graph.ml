open! Stdune
open Import
open Build.O

type t =
  { dir        : Path.Build.t
  ; per_module : (Module.t * (unit, Module.t list) Build.t) Module.Obj_map.t
  }

let make ~dir ~per_module = { dir ; per_module }

let deps_of t (m : Module.t) =
  match Module.Obj_map.find t.per_module m with
  | Some (_, x) -> x
  | None ->
    Code_error.raise "Ocamldep.Dep_graph.deps_of"
      [ "dir", Path.Build.to_dyn t.dir
      ; "modules", Dyn.Encoder.(list string)
                     (Module.Obj_map.keys t.per_module
                      |> List.map ~f:Module.obj_name)
      ; "m", Module.to_dyn m
      ]

let pp_cycle fmt cycle =
  (Fmt.list ~pp_sep:Fmt.nl (Fmt.prefix (Fmt.string "-> ") Module.Name.pp))
    fmt (List.map cycle ~f:Module.name)

let top_closed t modules =
  Module.Obj_map.to_list t.per_module
  |> List.map ~f:(fun (unit, (_module, deps)) ->
    deps >>^ fun deps -> (unit, deps))
  |> Build.all
  >>^ fun per_module ->
  let per_module = Module.Obj_map.of_list_exn per_module in
  match
    Module.Name.Top_closure.top_closure modules
      ~key:Module.name
      ~deps:(fun m ->
        Module.Obj_map.find per_module m
        |> Option.value_exn)
  with
  | Ok modules -> modules
  | Error cycle ->
    die "dependency cycle between modules in %s:\n   %a"
      (Path.Build.to_string t.dir)
      pp_cycle cycle

module Multi = struct
  let top_closed_multi (ts : t list) modules =
    List.concat_map ts ~f:(fun t ->
      Module.Obj_map.to_list t.per_module
      |> List.map ~f:(fun (_name, (unit, deps)) ->
        deps >>^ fun deps -> (unit, deps)))
    |> Build.all >>^ fun per_module ->
    let per_obj =
      Module.Obj_map.of_list_reduce per_module ~f:List.rev_append in
    match Module.Obj_map.top_closure per_obj modules with
    | Ok modules -> modules
    | Error cycle ->
      die "dependency cycle between modules\n   %a"
        pp_cycle cycle
end

let make_top_closed_implementations ~name ~f ts modules =
  Build.memoize name (
    let filter_out_intf_only = List.filter ~f:(Module.has ~ml_kind:Impl) in
    f ts (filter_out_intf_only modules)
    >>^ filter_out_intf_only)

let top_closed_multi_implementations =
  make_top_closed_implementations
    ~name:"top sorted multi implementations" ~f:Multi.top_closed_multi

let top_closed_implementations =
  make_top_closed_implementations
    ~name:"top sorted implementations" ~f:top_closed

let dummy (m : Module.t) =
  { dir = Path.Build.root
  ; per_module = Module.Obj_map.singleton m (m, (Build.return []))
  }

let wrapped_compat ~modules ~wrapped_compat =
  { dir = Path.Build.root
  ; per_module =
      Module.Name.Map.fold wrapped_compat ~init:Module.Obj_map.empty
        ~f:(fun compat acc ->
          let wrapped =
            let name = Module.name compat in
            match Module.Name.Map.find modules name with
            | Some m -> m
            | None ->
              Code_error.raise "deprecated module needs counterpart"
                [ "compat", Module.to_dyn compat ]
          in
          (* TODO this is wrong. The dependencies should be on the lib interface
             whenever it exists *)
          Module.Obj_map.add acc compat (compat, (Build.return [wrapped])))
  }

module Ml_kind = struct
  type nonrec t = t Ml_kind.Dict.t

  let dummy m =
    Ml_kind.Dict.make_both (dummy m)

  let wrapped_compat =
    let w = wrapped_compat in
    fun ~modules ~wrapped_compat ->
      Ml_kind.Dict.make_both (w ~modules ~wrapped_compat)

  let merge_impl ~(ml_kind : Ml_kind.t) _ vlib impl =
    match vlib, impl with
    | None, None -> assert false
    | Some _, None -> None (* we don't care about internal vlib deps *)
    | None, Some d -> Some d
    | Some (mv, _), Some (mi, i) ->
      if Module.obj_name mv = Module.obj_name mi
      && Module.kind mv = Virtual
      && Module.kind mi = Impl_vmodule
      then
        match ml_kind with
        | Impl -> Some (mi, i)
        | Intf -> None
      else if Module.visibility mv = Private
           || Module.visibility mi = Private then
        Some (mi, i)
      else
        Code_error.raise "merge_impl: unexpected dep graph"
          [ "ml_kind", (Ml_kind.to_dyn ml_kind)
          ; "mv", Module.to_dyn mv
          ; "mi", Module.to_dyn mi
          ]

  let merge_for_impl ~(vlib : t) ~(impl : t) =
    Ml_kind.Dict.of_func (fun ~ml_kind ->
      let impl = Ml_kind.Dict.get impl ml_kind in
      { impl with
        per_module =
          Module.Obj_map.merge ~f:(merge_impl ~ml_kind)
            (Ml_kind.Dict.get vlib ml_kind).per_module
            impl.per_module
      })
end
