from strformat import `&`

--gc:orc
--threads:on

if defined(release) or defined(danger):
  --opt:speed
  --passC:"-flto"
  --passL:"-flto"

const
  projName = "tetronimia"

task build, "Build executable":
  selfExec(&"c --define:release --out:{projName} src/{projName}.nim")
