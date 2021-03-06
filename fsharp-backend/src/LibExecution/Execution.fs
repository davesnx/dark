module LibExecution.Execution

open System.Threading.Tasks
open FSharp.Control.Tasks
open Runtime

let run (e : Expr) (fns : List<BuiltInFn>) : Task<Dval> =
  task {
    let functions = fns |> List.map (fun fn -> (fn.name, fn)) |> Map

    let state = { functions = functions; tlid = (int64 7) }
    let result = Interpreter.eval state Symtable.empty e

    match result with
    | Prelude.Task t -> return! t
    | Prelude.Value v -> return v
  }
