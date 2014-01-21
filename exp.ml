(** An expression. *)
open Typedtree
open Types
open SmartPrint

(** The simplified OCaml AST we use. *)
type t =
  | Constant of Constant.t
  | Variable of PathName.t
  | Tuple of t list (** A tuple of expressions. *)
  | Constructor of PathName.t * t list (** A constructor name and a list of arguments. *)
  | Apply of t * t (** An application. *)
  | Function of Name.t * t (** An argument name and a body. *)
  | Let of Name.t * t * t (** A "let" of a non-functional value. *)
  | LetFun of Recursivity.t * Name.t * Name.t list * (Name.t * Type.t) list * Type.t * t * t
    (** A "let" of a function: the recursivity flag, the function name, the type variables,
        the names and types of the arguments, the return type, the body and the expression
        in which we do the "let". We need to group [Let] and [Function] in one constructor
        to make the Coq's fixpoint operator work (and have a nicer pretty-printing). *)
  | Match of t * (Pattern.t * t) list (** Match an expression to a list of patterns. *)
  | Record of (PathName.t * t) list (** Construct a record giving an expression for each field. *)
  | Field of t * PathName.t (** Access to a field of a record. *)
  | IfThenElse of t * t * t (** The "else" part may be unit. *)
  | Sequence of t * t (** A sequence of two expressions. *)
  | Lift of Effect.Descriptor.t * Effect.Descriptor.t * t
    (** Monadic return. *)
  | Bind of t * Name.t * t
    (** Monadic bind. *)

let rec pp (e : t) : SmartPrint.t =
  match e with
  | Constant c -> Constant.pp c
  | Variable x -> PathName.pp x
  | Tuple es -> nest (!^ "Tuple" ^^ Pp.list (List.map pp es))
  | Constructor (x, es) ->
    nest (!^ "Constructor" ^^ Pp.list (PathName.pp x :: List.map pp es))
  | Apply (e_f, e_x) ->
    nest (!^ "Apply" ^^ Pp.list [pp e_f; pp e_x])
  | Function (x, e) ->
    nest (!^ "Function" ^^ Pp.list [Name.pp x; pp e])
  | Let (x, e1, e2) ->
    nest (!^ "Let" ^^ Pp.list [Name.pp x; pp e1; pp e2])
  | LetFun (is_rec, x, typ_vars, args, typ, e1, e2) ->
    nest (!^ "LetFun" ^^ Pp.list [
      Recursivity.pp is_rec; Name.pp x; OCaml.list Name.pp typ_vars;
      OCaml.list (fun (x, typ) -> Pp.list [Name.pp x; Type.pp typ]) args;
      pp e1; pp e2])
  | Match (e, cases) ->
    nest (!^ "Match" ^^ Pp.list [pp e; cases |> OCaml.list (fun (p, e) ->
      nest @@ parens (Pattern.pp p ^-^ !^ "," ^^ pp e))])
  | Record fields ->
    nest (!^ "Record" ^^ Pp.list (fields |> List.map (fun (x, e) ->
      nest @@ parens (PathName.pp x ^-^ !^ "," ^^ pp e))))
  | Field (e, x) -> nest (!^ "Field" ^^ Pp.list [pp e; PathName.pp x])
  | IfThenElse (e1, e2, e3) ->
    nest (!^ "IfThenElse" ^^ Pp.list [pp e1; pp e2; pp e3])
  | Sequence (e1, e2) -> nest (!^ "Sequence" ^^ Pp.list [pp e1; pp e2])
  | Lift (d1, d2, e) ->
    nest (!^ "Lift" ^^
      Pp.list [Effect.Descriptor.pp d1; Effect.Descriptor.pp d2; pp e])
  | Bind (e1, x, e2) -> nest (!^ "Bind" ^^ Pp.list [pp e1; Name.pp x; pp e2])

(** Take a function expression and make explicit the list of arguments and the body. *)
let rec open_function (e : t) : Name.t list * t =
  match e with
  | Function (x, e) ->
    let (xs, e) = open_function e in
    (x :: xs, e)
  | _ -> ([], e)

(** Import an OCaml expression. *)
let rec of_expression (e : expression) : t =
  match e.exp_desc with
  | Texp_ident (path, _, _) -> Variable (PathName.of_path path)
  | Texp_constant constant -> Constant (Constant.of_constant constant)
  | Texp_let (rec_flag, [{vb_pat = {pat_desc = Tpat_var (name, _)}; vb_expr = e1}], e2) ->
    let (rec_flag, name, free_typ_vars, args, body_typ, body) =
      import_let_fun rec_flag name e1 in
    let e2 = of_expression e2 in
    if args = [] then
      Let (name, body, e2)
    else
      LetFun (rec_flag, name, free_typ_vars, args, body_typ, body, e2)
  | Texp_function (_, [{c_lhs = {pat_desc = Tpat_var (x, _)}; c_rhs = e}], _) ->
    Function (Name.of_ident x, of_expression e)
  | Texp_function (_, cases, _) ->
    let (x, e) = open_cases cases in
    Function (x, e)
  | Texp_apply (e_f, e_xs) ->
    let e_f = of_expression e_f in
    let e_xs = List.map (fun (_, e_x, _) ->
      match e_x with
      | Some e_x -> of_expression e_x
      | None -> failwith "expected an argument") e_xs in
    List.fold_left (fun e e_x -> Apply (e, e_x)) e_f e_xs
  | Texp_match (e, cases, _) ->
    let e = of_expression e in
    let cases = List.map (fun {c_lhs = p; c_rhs = e} -> (Pattern.of_pattern p, of_expression e)) cases in
    Match (e, cases)
  | Texp_tuple es -> Tuple (List.map of_expression es)
  | Texp_construct (x, _, es) -> Constructor (PathName.of_loc x, List.map of_expression es)
  | Texp_record (fields, _) -> Record (List.map (fun (x, _, e) -> (PathName.of_loc x, of_expression e)) fields)
  | Texp_field (e, x, _) -> Field (of_expression e, PathName.of_loc x)
  | Texp_ifthenelse (e1, e2, e3) ->
    let e3 = match e3 with
      | None -> Constructor ({ PathName.path = []; base = "tt" }, [])
      | Some e3 -> of_expression e3 in
    IfThenElse (of_expression e1, of_expression e2, e3)
  | Texp_sequence (e1, e2) -> Sequence (of_expression e1, of_expression e2)
  | Texp_try _ | Texp_setfield _ | Texp_array _
    | Texp_while _ | Texp_for _ | Texp_assert _ ->
    failwith "Imperative expression not handled."
  | _ -> failwith "Expression not handled."
(** Generate a variable and a "match" on this variable from a list of patterns. *)
and open_cases (cases : case list) : Name.t * t =
  let x = Name.unsafe_fresh "match_var" in
  let cases = cases |> List.map (fun {c_lhs = p; c_rhs = e} ->
    (Pattern.of_pattern p, of_expression e)) in
  (x, Match (Variable (PathName.of_name [] x), cases))
and import_let_fun (rec_flag : Asttypes.rec_flag) (name : Ident.t) (e : expression)
  : Recursivity.t * Name.t * Name.t list * (Name.t * Type.t) list * Type.t * t =
  let name = Name.of_ident name in
  let e_schema = Schema.of_type (Type.of_type_expr e.exp_type) in
  let e = of_expression e in
  let (args_names, e_body) = open_function e in
  let e_typ = e_schema.Schema.typ in
  let (args_typs, e_body_typ) = Type.open_type e_typ (List.length args_names) in
  (Recursivity.of_rec_flag rec_flag, name, e_schema.Schema.variables,
    List.combine args_names args_typs, e_body_typ, e_body)

module Tree = struct
  type t =
    | Leaf of Effect.t
    | Compound of t list * Effect.t
    | Apply of t * t * Effect.t
    | Function of t * Effect.t
    | Let of t * t * Effect.t
    | LetFun of t * t * Effect.t
    | Match of t * t list * Effect.t
    | Field of t * Effect.t
    | Sequence of t * t * Effect.t

  let effect (tree : t) : Effect.t =
    match tree with
    | Leaf effect | Compound (_, effect) | Apply (_, _, effect)
      | Function (_, effect) | Let (_, _, effect) | LetFun (_, _, effect)
      | Match (_, _, effect) | Field (_, effect)
      | Sequence (_, _, effect) -> effect

  let descriptor (tree : t) : Effect.Descriptor.t =
    (effect tree).Effect.descriptor

  let rec pp (tree : t) : SmartPrint.t =
    let aux constructor trees =
      nest (!^ constructor ^^ Pp.list (
        Effect.pp (effect tree) :: List.map pp trees)) in
    match tree with
    | Leaf _ -> aux "Leaf" []
    | Compound (trees, _) -> aux "Compound" trees
    | Apply (tree1, tree2, _) -> aux "Apply" [tree1; tree2]
    | Function (tree, _) -> aux "Function" [tree]
    | Let (tree1, tree2, _) -> aux "Let" [tree1; tree2]
    | LetFun (tree1, tree2, _) -> aux "LetFun" [tree1; tree2]
    | Match (tree, trees, _) -> aux "Match" (tree :: trees)
    | Field (tree, _) -> aux "Field" [tree]
    | Sequence (tree1, tree2, _) -> aux "Sequence" [tree1; tree2]
end

let rec to_tree (effects : Effect.Env.t) (e : t) : Tree.t =
  let compound (es : t list) : Tree.t =
    let trees = List.map (to_tree effects) es in
    let effects = List.map Tree.effect trees in
    let descriptor = Effect.Descriptor.union (
      List.map (fun effect -> effect.Effect.descriptor) effects) in
    let have_functional_effect = effects |> List.exists (fun effect ->
      not (Effect.Type.is_pure effect.Effect.typ)) in
    if have_functional_effect then
      failwith "Compounds cannot have functional effects."
    else
      Tree.Compound (trees,
        { Effect.descriptor = descriptor; typ = Effect.Type.Pure }) in
  match e with
  | Constant _ -> Tree.Leaf
    { Effect.descriptor = Effect.Descriptor.pure;
      typ = Effect.Type.Pure }
  | Variable x ->
    (try Tree.Leaf
      { Effect.descriptor = Effect.Descriptor.pure;
        typ = Effect.Env.find x effects }
    with Not_found -> failwith (SmartPrint.to_string 80 2
      (PathName.pp x ^^ !^ "not found.")))
  | Tuple es | Constructor (_, es) -> compound es
  | Apply (e_f, e_x) ->
    let tree_f = to_tree effects e_f in
    let effect_f = Tree.effect tree_f in
    let tree_x = to_tree effects e_x in
    let effect_x = Tree.effect tree_x in
    if Effect.Type.is_pure effect_x.Effect.typ then
      let descriptor = Effect.Descriptor.union [
        effect_f.Effect.descriptor; effect_x.Effect.descriptor;
        Effect.Type.return_descriptor effect_f.Effect.typ] in
      let effect_typ = Effect.Type.return_type effect_f.Effect.typ in
      Tree.Apply (tree_f, tree_x,
        { Effect.descriptor = descriptor; typ = effect_typ })
    else
      failwith "Fucntion arguments cannot have functional effects."
  | Function (x, e) ->
    let tree_e = to_tree (Effect.Env.add (PathName.of_name [] x)
      Effect.Type.Pure effects) e in
    let effect_e = Tree.effect tree_e in
    Tree.Function (tree_e,
      { Effect.descriptor = Effect.Descriptor.pure;
        typ = Effect.Type.Arrow (
          effect_e.Effect.descriptor, effect_e.Effect.typ) })
  | Let (x, e1, e2) ->
    let tree1 = to_tree effects e1 in
    let effect1 = Tree.effect tree1 in
    let tree2 = to_tree (Effect.Env.add (PathName.of_name [] x)
      effect1.Effect.typ effects) e2 in
    let effect2 = Tree.effect tree2 in
    let descriptor = Effect.Descriptor.union
      [effect1.Effect.descriptor; effect2.Effect.descriptor] in
    Tree.Let (tree1, tree2,
      { Effect.descriptor = descriptor;
        typ = effect2.Effect.typ })
  | LetFun (is_rec, x, _, args, _, e1, e2) ->
    let (tree1, x_typ) = to_tree_let_fun effects is_rec x args e1 in
    let effects_in_e2 = Effect.Env.add (PathName.of_name [] x) x_typ effects in
    let tree2 = to_tree effects_in_e2 e2 in
    let effect2 = Tree.effect tree2 in
    Tree.LetFun (tree1, tree2, effect2)
  | Match (e, cases) ->
    let tree_e = to_tree effects e in
    let effect_e = Tree.effect tree_e in
    if Effect.Type.is_pure effect_e.Effect.typ then
      let trees = cases |> List.map (fun (p, e) ->
        let pattern_vars = Pattern.free_vars p in
        let effects = Name.Set.fold (fun x effects ->
          Effect.Env.add (PathName.of_name [] x) Effect.Type.Pure effects)
          pattern_vars effects in
        to_tree effects e) in
      let effect = Effect.union (List.map Tree.effect trees) in
      Tree.Match (tree_e, trees,
        { Effect.descriptor = Effect.Descriptor.union
            [effect_e.Effect.descriptor; effect.Effect.descriptor];
          typ = effect.Effect.typ })
    else
      failwith "Cannot match a value with functional effects."
  | Record fields -> compound (List.map snd fields)
  | Field (e, _) ->
    let tree = to_tree effects e in
    let effect = Tree.effect tree in
    if Effect.Type.is_pure effect.Effect.typ then
      Tree.Field (tree, effect)
    else
      failwith "Cannot take a field of a value with functional effects."
  | IfThenElse (e1, e2, e3) ->
    let tree_e1 = to_tree effects e1 in
    let effect_e1 = Tree.effect tree_e1 in
    if Effect.Type.is_pure effect_e1.Effect.typ then
      let trees = List.map (to_tree effects) [e2; e3] in
      let effect = Effect.union (List.map Tree.effect trees) in
      Tree.Match (tree_e1, trees,
        { Effect.descriptor = Effect.Descriptor.union
            [effect_e1.Effect.descriptor; effect.Effect.descriptor];
          typ = effect.Effect.typ })
    else
      failwith "Cannot do an if on a value with functional effects."
  | Sequence (e1, e2) ->
    let tree_e1 = to_tree effects e1 in
    let effect_e1 = Tree.effect tree_e1 in
    let tree_e2 = to_tree effects e2 in
    let effect_e2 = Tree.effect tree_e2 in
    Tree.Sequence (tree_e1, tree_e2,
      { Effect.descriptor = Effect.Descriptor.union
          [effect_e1.Effect.descriptor; effect_e2.Effect.descriptor];
        typ = effect_e2.Effect.typ })
  | Lift _ | Bind _ ->
    failwith "Cannot compute effects on an explicit lift or bind."

  and to_tree_let_fun (effects : Effect.Env.t)
    (is_rec : Recursivity.t) (x : Name.t) (args : (Name.t * Type.t) list)
    (e : t) : Tree.t * Effect.Type.t =
    let effects_in_e = Effect.Env.in_function effects args in
    if Recursivity.to_bool is_rec then
      let rec fix_tree x_typ =
        let effects_in_e = Effect.Env.add (PathName.of_name [] x)
          x_typ effects_in_e in
        let tree = to_tree effects_in_e e in
        let effect = Tree.effect tree in
        let x_typ' =
          match Effect.function_typ args effect with
          | Some typ -> typ
          | None -> failwith "Toplevel values cannot have effects." in
        if Effect.Type.eq x_typ x_typ' then
          (tree, x_typ)
        else
          fix_tree x_typ' in
      fix_tree Effect.Type.Pure
    else
      let tree = to_tree effects_in_e e in
      let effect = Tree.effect tree in
      let x_typ =
        match Effect.function_typ args effect with
        | Some typ -> typ
        | None -> failwith "Toplevel values cannot have effects." in
      (tree, x_typ)

let rec monadise (env : PathName.Env.t) (e : t) (tree : Tree.t) : t =
  let var (x : Name.t) : t = Variable (PathName.of_name [] x) in
  let lift d1 d2 e =
    if Effect.Descriptor.eq d1 d2 then
      e
    else
      Lift (d1, d2, e) in
  (** [d1] is the descriptor of [e1], [d2] of [e2]. *)
  let bind d1 d2 e1 x e2 =
    if Effect.Descriptor.is_pure d1 then
      Let (x, e1, e2)
    else
      Bind (lift d1 d2 e1, x, e2) in
  (** [k es'] is supposed to raise the effect [d]. *)
  let rec monadise_list env es trees d es' k =
    match (es, trees) with
    | ([], []) -> k (List.rev es')
    | (e :: es, tree :: trees) ->
      let d_e = Tree.descriptor tree in
      if Effect.Descriptor.is_pure d_e then
        monadise_list env es trees d (e :: es') k
      else
        let e' = monadise env e tree in
        let (x, env) = PathName.Env.fresh "x" env in
        bind d_e d e' x
          (monadise_list env es trees d (var x :: es') k)
    | _ -> failwith "Unexpected number of trees." in
  let d = Tree.descriptor tree in
  match (e, tree) with
  | (Constant _, Tree.Leaf _) | (Variable _, Tree.Leaf _) -> e
  | (Tuple es, Tree.Compound (trees, _)) ->
    monadise_list env es trees d [] (fun es' ->
      lift Effect.Descriptor.pure d (Tuple es'))
  | (Constructor (x, es), Tree.Compound (trees, _)) ->
    monadise_list env es trees d [] (fun es' ->
      lift Effect.Descriptor.pure d (Constructor (x, es')))
  | (Apply (e1, e2), Tree.Apply (tree1, tree2, _)) ->
    monadise_list env [e1; e2] [tree1; tree2] d [] (fun es' ->
      match es' with
      | [e1; e2] ->
        let return_descriptor =
          Effect.Type.return_descriptor (Tree.effect tree1).Effect.typ in
        lift return_descriptor d (Apply (e1, e2))
      | _ -> failwith "Wrong answer from 'monadise_list'.")
  | (Function (x, e), Tree.Function (tree, _)) ->
    let env = PathName.Env.add (PathName.of_name [] x) env in
    Function (x, monadise env e tree)
  | (Let (x, e1, e2), Tree.Let (tree1, tree2, _)) ->
    let e1 = monadise env e1 tree1 in
    let env = PathName.Env.add (PathName.of_name [] x) env in
    let e2 = monadise env e2 tree2 in
    bind (Tree.descriptor tree1) (Tree.descriptor tree2) e1 x e2
  | _ -> failwith "TODO"
 
let added_vars_in_let_fun (is_rec : Recursivity.t) (f : Name.t)
  (xs : (Name.t * Type.t) list) : Name.Set.t =
  let s = List.fold_left (fun s (x, _) -> Name.Set.add x s)
    Name.Set.empty xs in
  if Recursivity.to_bool is_rec then
    Name.Set.add f s
  else
    s
(*
(** Simplify binds of a return and lets of a variable. *)
let simplify (e : t) : t =
  (** The [env] is the environment of substitutions to make. *)
  let rec aux (env : t Name.Map.t) (e : t) : t =
    let rm x = Name.Map.remove x env in
    match e with
    | Bind (Return (d1, d2, e1), x, e2) -> aux env (Let (x, e1, e2))
    | Let (x, Variable x', e2) -> aux (Name.Map.add x (Variable x') env) e2
    | Variable x ->
      (match x with
      | { PathName.path = []; base = x } ->
        if Name.Map.mem x env then
          Name.Map.find x env
        else
          e
      | _ -> e)
    | Constant _ -> e
    | Tuple es -> Tuple (List.map (aux env) es)
    | Constructor (x, es) -> Constructor (x, List.map (aux env) es)
    | Apply (e_f, e_x) -> Apply (aux env e_f, aux env e_x)
    | Function (x, e) -> Function (x, aux (rm x) e)
    | Let (x, e1, e2) -> Let (x, aux env e1, aux (rm x) e2)
    | LetFun (is_rec, f, typ_vars, xs, f_typ, e1, e2) ->
      let env_in_f = Name.Set.fold (fun x env ->
        Name.Map.remove x env)
        (added_vars_in_let_fun is_rec f xs)
        env in
      LetFun (is_rec, f, typ_vars, xs, f_typ, aux env_in_f e1, aux (rm f) e2)
    | Match (e, cases) -> Match (aux env e, cases |> List.map (fun (p, e) ->
      let env = Name.Set.fold (fun x env -> Name.Map.remove x env) (Pattern.free_vars p) env in
      (p, aux env e)))
    | Record fields -> Record (fields |> List.map (fun (x, e) -> (x, aux env e)))
    | Field (e, x) -> Field (aux env e, x)
    | IfThenElse (e1, e2, e3) -> IfThenElse (aux env e1, aux env e2, aux env e3)
    | Sequence (e1, e2) -> Sequence (aux env e1, aux env e2)
    | Return (d1, d2, e) -> Return (d1, d2, aux env e)
    | Bind (e1, x, e2) -> Bind (aux env e1, x, aux (rm x) e2) in
  aux Name.Map.empty e*)

(** Pretty-print an expression to Coq (inside parenthesis if the [paren] flag is set). *)
let rec to_coq (paren : bool) (e : t) : SmartPrint.t =
  match e with
  | Constant c -> Constant.to_coq c
  | Variable x -> PathName.to_coq x
  | Tuple es -> parens @@ nest @@ separate (!^ "," ^^ space) (List.map (to_coq true) es)
  | Constructor (x, es) ->
    if es = [] then
      PathName.to_coq x
    else
      Pp.parens paren @@ nest @@ separate space (PathName.to_coq x :: List.map (to_coq true) es)
  | Apply (e_f, e_x) ->
    Pp.parens paren @@ nest @@ (to_coq true e_f ^^ to_coq true e_x)
  | Function (x, e) ->
    Pp.parens paren @@ nest (!^ "fun" ^^ Name.to_coq x ^^ !^ "=>" ^^ to_coq false e)
  | Let (x, e1, e2) ->
    Pp.parens paren @@ nest (
      !^ "let" ^^ Name.to_coq x ^^ !^ ":=" ^^ to_coq false e1 ^^ !^ "in" ^^ newline ^^ to_coq false e2)
  | LetFun (is_rec, f_name, typ_vars, xs, f_typ, e_f, e) ->
    Pp.parens paren @@ nest (
      !^ "let" ^^
      (if Recursivity.to_bool is_rec then !^ "fix" else empty) ^^
      Name.to_coq f_name ^^
      (if typ_vars = []
      then empty
      else braces @@ group (
        separate space (List.map Name.to_coq typ_vars) ^^
        !^ ":" ^^ !^ "Type")) ^^
      group (separate space (xs |> List.map (fun (x, x_typ) ->
        parens (Name.to_coq x ^^ !^ ":" ^^ Type.to_coq false x_typ)))) ^^
      !^ ":" ^^ Type.to_coq false f_typ ^^ !^ ":=" ^^ newline ^^
      indent (to_coq false e_f) ^^ !^ "in" ^^ newline ^^
      to_coq false e)
  | Match (e, cases) ->
    nest (
      !^ "match" ^^ to_coq false e ^^ !^ "with" ^^ newline ^^
      separate space (cases |> List.map (fun (p, e) ->
        nest (!^ "|" ^^ Pattern.to_coq false p ^^ !^ "=>" ^^ to_coq false e ^^ newline))) ^^
      !^ "end")
  | Record fields ->
    nest (!^ "{|" ^^ separate (!^ ";" ^^ space) (fields |> List.map (fun (x, e) ->
      nest (PathName.to_coq x ^^ !^ ":=" ^^ to_coq false e))) ^^ !^ "|}")
  | Field (e, x) -> Pp.parens paren @@ nest (PathName.to_coq x ^^ to_coq true e)
  | IfThenElse (e1, e2, e3) ->
    nest (
      !^ "if" ^^ to_coq false e1 ^^ !^ "then" ^^ newline ^^
      indent (to_coq false e2) ^^ newline ^^
      !^ "else" ^^ newline ^^
      indent (to_coq false e3))
  | Sequence (e1, e2) ->
    nest (to_coq true e1 ^-^ !^ ";" ^^ newline ^^ to_coq false e2)
  | Lift (d1, d2, e) -> (* TODO: print d1 and d2. *)
    to_coq paren (Apply (Variable (PathName.of_name [] "lift"), e))
  | Bind (e1, x, e2) ->
    Pp.parens paren @@ nest (
      !^ "let!" ^^ Name.to_coq x ^^ !^ ":=" ^^ to_coq false e1 ^^ !^ "in" ^^ newline ^^
      to_coq false e2)