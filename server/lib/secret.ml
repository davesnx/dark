(* Keys for: https://apps.twitter.com/app/14082455 *)
let twitter_bearer_token =
  "AAAAAAAAAAAAAAAAAAAAAJfh1gAAAAAAazXXwsaMuN"
  ^ "yK2a8ZsTGVX32KdXY%3DzKh8JxqSB8tkLKzVgEY3"
  ^ "Pagi8le92ZQE5PXTqimhtVRqyjeWRz"

let twitter_CONSUMER_KEY =
  "FOohmxHC3ExCFvLVbl8UySqFu"

let twitter_CONSUMER_SECRET =
  "J5GgPfzqQvxSyjQFqP8MDE4diuZS87KtUDdhb1vBFA5BX0o7rP"

(* Secrets for @paulbiggar and this app *)
let paulbiggar_ACCESS_TOKEN =
  "86938585-uDxKWfIywAVnV7bVOnL171lFgQ45OIbswteqmMMSx"

let paulbiggar_ACCESS_TOKEN_SECRET =
  "QzmAJlKk5HwYYHNrNLTr9V8NM9hzFyudVoHShOki7HKdz"

type twitter_secret = { consumer_key: string
                      ; consumer_secret: string
                      ; access_token: string
                      ; access_token_secret: string }

let twitter = { consumer_key = twitter_CONSUMER_KEY
              ; consumer_secret = twitter_CONSUMER_SECRET
              ; access_token = paulbiggar_ACCESS_TOKEN
              ; access_token_secret = paulbiggar_ACCESS_TOKEN_SECRET
              }
