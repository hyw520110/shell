# Keep the 16-field metadata format shared with parse_tool_data.
def clean: (. // "") | tostring | gsub("[\r\n\t]+"; " ");
def fallback($v): if . == "" then $v else . end;
input_filename as $file |
(.id | clean | fallback($file | split("/")[-1] | sub("[.]json$"; ""))) as $id |
(.name | clean | fallback($id)) as $name |
(.install.methods[0].type | clean | fallback("unknown")) as $type |
(.install.methods[0].command | clean) as $install |
(.commands.start // .id | clean | fallback($id) | [scan("\\S+")][0] // $id) as $cmd |
($file | split("/")[-2]) as $subdir |
({cli:"ai-coding", ide:"ai-ide", gateway:"ai-gateway", agent:"ai-agent",
  runtime:"ai-runtime", optimizer:"ai-optimizer", workbench:"ai-workbench",
  utility:"ai-utility"}[$subdir] // "") as $category |
((.sort_order // .order // 5000) | tostring |
    if test("^[0-9]+$") then tonumber else 5000 end) as $order |
(.sort_key | clean | fallback($name)) as $sort_key |
(if $install == "" then ""
 elif $type == "npm" then
    ($install | sub(".*npm install -g (?<pkg>[^ ]+).*"; "\(.pkg)") |
     split(" ")[0] | sub("--.*"; ""))
 elif $type == "pip" or $type == "pip_official" then
    ($install | sub(".*pip3 install (?<pkg>[^ ]+).*"; "\(.pkg)"))
 elif $type == "brew" then
    ([$install | capture(".*brew install (?<pkg>[^ ]*)").pkg][0] // "")
 else "" end |
 if . == "" and ($type == "npm" or $type == "pip") then $id else . end) as $pkg |
[
 $id, $name, $pkg, $type, (.install.methods[0].plugin | clean),
 (.config.path | clean | split("$HOME") | join($user_home)), "", $cmd,
 (.commands.version | clean), (.description | clean),
 (.category | clean | fallback($category)), $file,
 (.install.methods[0].check | if type == "string" then clean else "" end),
 ($order | tostring), $sort_key, (.group | clean)
] | join($sep) as $line |
[($order | tostring), $sort_key, $file, $line] | join("\t")
