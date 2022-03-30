from strformat import `&`

--gc:orc
--threads:on

if defined(release) or defined(danger):
  --opt:speed
  --passC:"-flto"
  --passL:"-flto"

const projectName = "tetronimia"

############ Tasks
task build, "Build executable":
  selfExec(&"c --define:release --out:{projectName} src/{projectName}.nim")
