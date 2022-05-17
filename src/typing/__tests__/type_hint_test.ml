(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open OUnit2
open Reason
open Type_hint

let metadata =
  {
    Context.checked = true;
    include_suppressions = false;
    jsx = Options.Jsx_react;
    munge_underscores = false;
    strict = false;
    strict_local = false;
    (* Provide some useful error traces for debugging when some tests fail. *)
    verbose =
      Some Verbose.{ indent = 2; depth = 10; enabled_during_flowlib = false; focused_files = None };
    any_propagation = true;
    automatic_require_default = false;
    babel_loose_array_spread = false;
    cycle_errors = false;
    enable_const_params = false;
    enable_contextual_typing = true;
    enable_enums = true;
    enable_relay_integration = false;
    enforce_local_inference_annotations = false;
    enforce_strict_call_arity = true;
    enforce_this_annotations = false;
    env_mode = Options.ClassicEnv [];
    env_mode_constrain_write_dirs = [];
    exact_by_default = true;
    exact_empty_objects = false;
    experimental_infer_indexers = false;
    facebook_fbs = None;
    facebook_fbt = None;
    facebook_module_interop = false;
    haste_module_ref_prefix = None;
    ignore_non_literal_requires = false;
    local_inference_annotation_dirs = [];
    max_literal_length = 100;
    max_trace_depth = 0;
    max_workers = 0;
    missing_module_generators = [];
    react_runtime = Options.ReactRuntimeClassic;
    react_server_component_exts = SSet.empty;
    recursion_limit = 10000;
    relay_integration_excludes = [];
    relay_integration_module_prefix = None;
    relay_integration_module_prefix_includes = [];
    root = Path.dummy_path;
    run_post_inference_implicit_instantiation = false;
    statement_reorder_checking = Options.Lexical;
    strict_es6_import_export = false;
    strict_es6_import_export_excludes = [];
    strip_root = true;
    suppress_types = SSet.empty;
    trust_mode = Options.NoTrust;
    type_asserts = false;
  }

let dummy_filename = File_key.SourceFile ""

let dummy_reason = locationless_reason (RCustom "dummy_reason")

(**************************)
(* Parse and convert type *)
(**************************)

module TypeParser : sig
  val parse : Context.t -> string -> Type.t
end = struct
  let parse_type content =
    let parse_options =
      Some
        {
          Parser_env.enums = true;
          esproposal_decorators = true;
          esproposal_export_star_as = true;
          types = true;
          use_strict = false;
        }
    in
    (* the parser expects a colon *)
    let content = ": " ^ content in
    let (t, errs) = Parser_flow.parse_annot ~parse_options (Some dummy_filename) content in
    assert (List.length errs = 0);
    Ast_loc_utils.loc_to_aloc_mapper#type_annotation t

  module New_env : Env_sig.S = New_env.New_env

  module rec Statement_ : (Statement_sig.S with module Env := New_env) =
    Statement.Make (New_env) (Destructuring_) (Func_stmt_config_) (Statement_)

  and Destructuring_ : Destructuring_sig.S = Destructuring.Make (New_env) (Statement_)

  and Func_stmt_config_ :
    (Func_stmt_config_sig.S with module Types := Func_stmt_config_types.Types) =
    Func_stmt_config.Make (New_env) (Destructuring_) (Statement_)

  module Annot = Type_annotation.Make (New_env) (Statement_.Abnormal) (Statement_)

  let parse cx content =
    let (_, t_ast) = parse_type content in
    (* The object type converter will peek the scope, so we need to have a non-empty scope list. *)
    New_env.init_env cx (Scope.fresh ~var_scope_kind:Scope.Global ());
    let ((_, t), _) = Annot.convert cx Subst_name.Map.empty t_ast in
    t
end

module LibDefLoader : sig
  val get_master_cx : unit -> Context.master_context
end = struct
  let parse_content file content =
    let parse_options =
      Some
        {
          Parser_env.enums = true;
          (*
           * Always parse ES proposal syntax. The user-facing config option to
           * ignore/warn/enable them is handled during inference so that a clean error
           * can be surfaced (rather than a more cryptic parse error).
           *)
          esproposal_decorators = true;
          esproposal_export_star_as = true;
          types = true;
          use_strict = false;
        }
    in

    let (ast, _) = Parser_flow.program_file ~fail:false ~parse_options content (Some file) in
    let (fsig, _) = File_sig.With_Loc.program ~ast ~opts:File_sig.With_Loc.default_opts in
    (ast, fsig)

  (* No verbose mode during libdef init. *)
  let metadata = { metadata with Context.verbose = None }

  let load_lib_files ccx =
    (* iterate in reverse override order *)
    let (leader, _) =
      Flowlib.contents_list ~no_flowlib:false
      |> List.fold_left
           (fun (_, exclude_syms) (filename, lib_content) ->
             let lib_file = File_key.LibFile filename in
             let (ast, file_sig) = parse_content lib_file lib_content in
             (* Lib files use only concrete locations, so this is not used. *)
             let aloc_table = lazy (ALoc.empty_table lib_file) in
             let cx = Context.make ccx metadata lib_file aloc_table Context.Checking in
             let syms =
               Type_inference_js.infer_lib_file
                 cx
                 ast
                 ~exclude_syms
                 ~file_sig:(File_sig.abstractify_locs file_sig)
                 ~lint_severities:LintSettings.empty_severities
             in
             (* symbols loaded from this file are suppressed if found in later ones *)
             (Some cx, NameUtils.Set.union exclude_syms (NameUtils.Set.of_list syms)))
           (None, NameUtils.Set.empty)
    in
    leader

  let init_master_cx () =
    let ccx = Context.(make_ccx (empty_master_cx ())) in
    match load_lib_files ccx with
    | None -> Context.empty_master_cx ()
    | Some cx ->
      Merge_js.optimize_builtins cx;
      { Context.master_sig_cx = Context.sig_cx cx; builtins = Context.builtins cx }

  let master_cx_ref = ref None

  let get_master_cx () =
    match !master_cx_ref with
    | Some master_cx -> master_cx
    | None ->
      let master_cx = init_master_cx () in
      master_cx_ref := Some master_cx;
      master_cx
end

let mk_cx () =
  let master_cx = LibDefLoader.get_master_cx () in
  let aloc_table = lazy (ALoc.empty_table dummy_filename) in
  let ccx = Context.(make_ccx master_cx) in
  Context.make ccx metadata dummy_filename aloc_table Context.Checking

let mk_hint cx base ops =
  let base_t = TypeParser.parse cx base in
  ops
  |> Nel.of_list
  |> Base.Option.value_map ~default:(Hint_t base_t) ~f:(fun l -> Hint_Decomp (l, base_t))

let mk_eval_hint_test ~expected base ops ctxt =
  let cx = mk_cx () in
  let actual =
    mk_hint cx base ops
    |> Type_hint.evaluate_hint cx
    |> Base.Option.value_map ~default:"None" ~f:(Ty_normalizer.debug_string_of_t cx)
  in
  assert_equal ~ctxt ~printer:Base.Fn.id expected actual

let eval_hint_tests =
  [
    "hint_t_num" >:: mk_eval_hint_test ~expected:"number" "number" [];
    "hint_t_array" >:: mk_eval_hint_test ~expected:"Array<number>" "Array<number>" [];
    "array_element_decomp_general"
    >:: mk_eval_hint_test ~expected:"number" "number[]" [Decomp_ArrElement 2];
    "array_element_decomp_specific"
    >:: mk_eval_hint_test ~expected:"string" "[number, string]" [Decomp_ArrElement 1];
    "array_element_decomp_specific_nonexistent"
    >:: mk_eval_hint_test ~expected:"None" "[number, string]" [Decomp_ArrElement 2];
    "array_spread_decomp_with_general"
    >:: mk_eval_hint_test ~expected:"Array<number>" "number[]" [Decomp_ArrSpread 0];
    "array_spread_decomp_with_tuple_full"
    >:: mk_eval_hint_test ~expected:"[number, string]" "[number, string]" [Decomp_ArrSpread 0];
    "array_spread_decomp_with_tuple_single"
    >:: mk_eval_hint_test ~expected:"[string]" "[number, string]" [Decomp_ArrSpread 1];
    "array_spread_decomp_with_tuple_part"
    >:: mk_eval_hint_test
          ~expected:"[string, number]"
          "[number, string, number]"
          [Decomp_ArrSpread 1];
    "fun_decomp_simple_return"
    >:: mk_eval_hint_test ~expected:"number" "(string, number) => number" [Decomp_FuncReturn];
    "fun_decomp_simple_on_first_argument_of_hint"
    >:: mk_eval_hint_test ~expected:"string" "(string, number) => number" [Decomp_FuncParam 0];
    "fun_decomp_simple_on_second_argument_of_hint"
    >:: mk_eval_hint_test ~expected:"number" "(string, number) => number" [Decomp_FuncParam 1];
    "fun_decomp_on_nonexistent_argument_of_hint"
    >:: mk_eval_hint_test ~expected:"void" "() => number" [Decomp_FuncParam 0];
    "fun_decomp_on_rest_arguments_of_hint"
    >:: mk_eval_hint_test ~expected:"number" "(...number[]) => number" [Decomp_FuncParam 0];
    "fun_decomp_rest_arguments_matching_number_of_normal_parameters"
    >:: mk_eval_hint_test
          ~expected:"Array<number>"
          "(string, number, ...number[]) => number"
          [Decomp_FuncRest 2];
    "fun_decomp_rest_arguments_with_additional_normal_parameters"
    >:: mk_eval_hint_test
          ~expected:"Array<string>"
          "(string, number, ...string[]) => number"
          [Decomp_FuncRest 3];
    "fun_decomp_rest_arguments_overlap_with_normal_parameters"
    >:: mk_eval_hint_test
          ~expected:"Array<(number | string)>"
          "(string, number, ...string[]) => number"
          [Decomp_FuncRest 1];
    "obj_prop_from_record_neutral_polarity"
    >:: mk_eval_hint_test ~expected:"number" "{foo: number}" [Decomp_ObjProp "foo"];
    "obj_prop_from_record_positive_polarity"
    >:: mk_eval_hint_test ~expected:"number" "{+foo: number}" [Decomp_ObjProp "foo"];
    "obj_prop_from_record_positive_polarity_from_readonly"
    >:: mk_eval_hint_test ~expected:"number" "$ReadOnly<{foo: number}>" [Decomp_ObjProp "foo"];
    "obj_prop_from_record_negative_polarity"
    >:: mk_eval_hint_test ~expected:"None" "{-foo: number}" [Decomp_ObjProp "foo"];
    "obj_prop_from_dict_neutral_polarity"
    >:: mk_eval_hint_test ~expected:"number" "{[string]: number}" [Decomp_ObjProp "foo"];
    "obj_prop_from_dict_positive_polarity"
    >:: mk_eval_hint_test ~expected:"number" "{+[string]: number}" [Decomp_ObjProp "foo"];
    "obj_prop_from_dict_negative_polarity"
    >:: mk_eval_hint_test ~expected:"None" "{-[string]: number}" [Decomp_ObjProp "foo"];
    "obj_prop_union"
    >:: mk_eval_hint_test
          ~expected:"number | string"
          "{foo: number} | {[string]: string}"
          [Decomp_ObjProp "foo"];
    "obj_prop_union_some_without_prop"
    >:: mk_eval_hint_test
          ~expected:"number | string | void"
          "{foo: number} | {[string]: string} | {bar: string}"
          [Decomp_ObjProp "foo"];
    (* TODO: Be more lenient with union branches that failed to match. *)
    "obj_prop_union_some_failed"
    >:: mk_eval_hint_test
          ~expected:"None"
          "{foo: number} | {[string]: string} | number"
          [Decomp_ObjProp "foo"];
    "obj_prop_intersection"
    >:: mk_eval_hint_test
          ~expected:"number"
          "{bar: string} & {foo: number} & {[string]: string}"
          [Decomp_ObjProp "foo"];
    "obj_prop_from_prototype"
    >:: mk_eval_hint_test ~expected:"number" "string" [Decomp_ObjProp "length"];
    "obj_computed_from_record_neutral_polarity"
    >:: mk_eval_hint_test ~expected:"any (implicit)" "{foo: number}" [Decomp_ObjComputed];
    "obj_computed_from_dict_neutral_polarity"
    >:: mk_eval_hint_test ~expected:"number" "{[string]: number}" [Decomp_ObjComputed];
    "obj_computed_from_dict_positive_polarity"
    >:: mk_eval_hint_test ~expected:"number" "{+[string]: number}" [Decomp_ObjComputed];
    "obj_computed_from_dict_negative_polarity"
    >:: mk_eval_hint_test ~expected:"None" "{-[string]: number}" [Decomp_ObjComputed];
    "obj_rest_from_record_neutral_polarity"
    >:: mk_eval_hint_test ~expected:"{foo: number}" "{foo: number}" [Decomp_ObjSpread];
    "obj_rest_from_record_positive_polarity"
    >:: mk_eval_hint_test ~expected:"{+foo: number}" "{+foo: number}" [Decomp_ObjSpread];
    "obj_rest_from_record_negative_polarity"
    >:: mk_eval_hint_test ~expected:"{-foo: number}" "{-foo: number}" [Decomp_ObjSpread];
    "obj_rest_from_dict_neutral_polarity"
    >:: mk_eval_hint_test ~expected:"{[string]: number}" "{[string]: number}" [Decomp_ObjSpread];
    "obj_rest_from_dict_positive_polarity"
    >:: mk_eval_hint_test ~expected:"{+[string]: number}" "{+[string]: number}" [Decomp_ObjSpread];
    "obj_rest_from_dict_negative_polarity"
    >:: mk_eval_hint_test ~expected:"{-[string]: number}" "{-[string]: number}" [Decomp_ObjSpread];
  ]

let tests = "type_hint" >::: ["evaluate_hint" >::: eval_hint_tests]