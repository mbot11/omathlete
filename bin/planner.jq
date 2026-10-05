def planner_game:
  type == "object"
  and (.sport | type == "string" and test("^(nfl|nba|wnba|mlb|nhl|cfb|cbb|epl|mls)$"))
  and (.id | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))
  and (.date | type == "string" and length <= 64)
  and (.homeTeam | type == "string" and length <= 40)
  and (.awayTeam | type == "string" and length <= 40)
  and (.broadcast | type == "string" and length <= 80)
  and (.gameUrl | type == "string" and length <= 512 and (. == "" or startswith("https://www.espn.com/")));
def game_snapshot:
  {sport,id,date,homeTeam,awayTeam,broadcast,gameUrl};
def planner_state:
  .watchLater = (if (.watchLater | type) == "array" then
    [.watchLater[:32][] | select(try planner_game catch false) | game_snapshot] | unique_by(.sport + ":" + .id)
    else [] end)
  | .reminders = (if (.reminders | type) == "array" then
    [.reminders[:32][] | select(try (planner_game and (.leadMinutes == 0 or .leadMinutes == 15)) catch false)
      | (game_snapshot + {leadMinutes})] | unique_by(.sport + ":" + .id) else [] end)
  | .quietHours = (if (.quietHours | type) == "boolean" then .quietHours else true end);
