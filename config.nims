from strformat import `&`

const
  projName = "tetronimia"

task build, "Build executable":
  selfExec(&"c --gc:orc --define:release --threads:on --out:{projName} src/{projName}.nim")
