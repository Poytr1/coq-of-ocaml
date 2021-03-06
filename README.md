# ![Logo](https://raw.githubusercontent.com/clarus/icons/master/abc-48.png) CoqOfOCaml
> Compile OCaml to Coq.

Start with the file `main.ml`:

    let head l =
      match l with
      | [] -> failwith "empty list"
      | x :: _ -> x

Run:

    ocamlc -bin-annot main.ml
    coqOfOCaml.native -mode v main.cmt

Get:

    Require Import OCaml.OCaml.

    Local Open Scope Z_scope.
    Local Open Scope type_scope.
    Import ListNotations.

    Definition head {A : Type} (l : list A) : M [ OCaml.Failure ] A :=
      match l with
      | [] => OCaml.Pervasives.failwith "empty list" % string
      | cons x _ => ret x
      end.

## Install
### With OPAM
Add the [Coq repository](http://coq.io/opam/):

    opam repo add coq-released https://coq.inria.fr/opam/released

and run:

    opam install coq-of-ocaml

### With Docker
Run the `Dockerfile` with:

    docker build --tag=coq-of-ocaml .

It will install the dependencies (can take time) and compile CoqOfOCaml. You can run the [Docker](https://www.docker.io/) image:

    docker run -ti coq-of-ocaml

and make the tests:

    eval `opam config env` # initialize the OPAM environment
    make test

### Manually
This compiler needs a working installation of OCaml 4.02 and Coq 8.4, plus the following packages (can be installed using [OPAM](http://opam.ocaml.org/)):
* [SmartPrint](https://github.com/clarus/smart-print)
* [YoJson](http://mjambon.com/yojson.html)

You have two parts to compile in order:

#### The Coq library
Go to `CoqOfOCaml/` and run:

    ./configure.sh
    make
    make install

#### The compiler
Go to the root folder and run:

    make
    make test

## Usage
CoqOfOCaml compiles the `.cmt` files (generated by the OCaml compiler using the option `-bin-annot`) to Coq definitions and print it on the standard output:

    coqOfOCaml.native -mode v file.cmt

You can start to experiment with the test files in `tests/`.

## License
MIT © Guillaume Claret.
