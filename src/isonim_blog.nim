## Public library entry point for the isonim-blog command interface.
import isonim_blog/[cli, version, model]
export cli, version, model
when not defined(js):
  import isonim_blog/[inputs, program]
  export inputs, program
