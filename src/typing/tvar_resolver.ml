(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Type
open Reason
open Utils_js

let resolver =
  object (this)
    inherit [bool] Type_visitor.t

    method! tvar cx pole require_resolution r id =
      let module C = Type.Constraint in
      let (root_id, root) = Context.find_root cx id in
      match root.C.constraints with
      | C.FullyResolved _ -> require_resolution
      | _ ->
        let t =
          match Flow_js_utils.merge_tvar_opt cx r root_id with
          | Some t -> Some t
          | None ->
            if Context.in_synthesis_mode cx then
              None
            else begin
              ( if require_resolution then
                let id_msg =
                  match Context.verbose cx with
                  | Some verbose when Debug_js.Verbose.verbose_in_file cx verbose -> Some root_id
                  | _ -> None
                in
                Flow_js_utils.add_output
                  cx
                  Error_message.(EInternal (aloc_of_reason r, UnconstrainedTvar id_msg))
              );
              let desc =
                match desc_of_reason r with
                | RIdentifier (OrdinaryName x) -> RCustom (spf "`%s` (resolved to type `empty`)" x)
                | _ -> REmpty
              in
              Some (EmptyT.make (replace_desc_reason desc r) (bogus_trust ()))
            end
        in
        Base.Option.iter t ~f:(fun t ->
            let root = C.Root { root with C.constraints = C.FullyResolved (unknown_use, lazy t) } in
            Context.add_tvar cx root_id root;
            let (_ : bool) = this#type_ cx pole require_resolution t in
            ()
        );
        require_resolution
  end

let resolve cx ~require_resolution t =
  match (Context.env_mode cx, Context.current_phase cx <> Context.InitLib) with
  | (Options.LTI, true) ->
    let (_ : bool) = resolver#type_ cx Polarity.Positive require_resolution t in
    ()
  | _ -> ()

let resolved_t cx ~require_resolution t =
  resolve cx ~require_resolution t;
  t
