"use strict";(self.webpackChunk=self.webpackChunk||[]).push([[9397],{90610:(e,n,t)=>{t.r(n),t.d(n,{assets:()=>u,contentTitle:()=>d,default:()=>y,frontMatter:()=>l,metadata:()=>p,toc:()=>m});var a=t(83117),i=t(80102),s=(t(67294),t(3905)),o=t(5406),r=["components"],l={id:"pysa-basics",title:"Overview",sidebar_label:"Overview"},d=void 0,p={unversionedId:"pysa-basics",id:"pysa-basics",title:"Overview",description:"Pyre has applications beyond type checking python code: it can also run static",source:"@site/docs/pysa_basics.md",sourceDirName:".",slug:"/pysa-basics",permalink:"/docs/pysa-basics",draft:!1,editUrl:"https://github.com/facebook/pyre-check/tree/main/documentation/website/docs/pysa_basics.md",tags:[],version:"current",frontMatter:{id:"pysa-basics",title:"Overview",sidebar_label:"Overview"},sidebar:"pysa",previous:{title:"Quickstart",permalink:"/docs/pysa-quickstart"},next:{title:"Feature Annotations",permalink:"/docs/pysa-features"}},u={},m=[{value:"Taint Analysis",id:"taint-analysis",level:2},{value:"Configuration",id:"configuration",level:2},{value:"Sources",id:"sources",level:2},{value:"Sinks",id:"sinks",level:2},{value:"Implicit Sinks",id:"implicit-sinks",level:3},{value:"Rules",id:"rules",level:2},{value:"Sanitizers",id:"sanitizers",level:2},{value:"TITO Sanitizers vs Source/Sink Sanitizers",id:"tito-sanitizers-vs-sourcesink-sanitizers",level:3},{value:"Taint Propagation",id:"taint-propagation",level:2},{value:"Features",id:"features",level:2},{value:"Model files",id:"model-files",level:2},{value:"Usage",id:"usage",level:3},{value:"Requirements and Features",id:"requirements-and-features",level:3},{value:"Fully qualified names",id:"fully-qualified-names",level:4},{value:"Matching signatures",id:"matching-signatures",level:4},{value:"Eliding",id:"eliding",level:4},{value:"Next Steps",id:"next-steps",level:2}],c=function(e){return function(n){return console.warn("Component "+e+" was not imported, exported, or provided by MDXProvider as global scope"),(0,s.mdx)("div",n)}},h=c("Internal"),f=c("FbInternalOnly"),g={toc:m};function y(e){var n=e.components,t=(0,i.Z)(e,r);return(0,s.mdx)("wrapper",(0,a.Z)({},g,t,{components:n,mdxType:"MDXLayout"}),(0,s.mdx)("p",null,"Pyre has applications beyond type checking python code: it can also run static\nanalysis, more specifically called ",(0,s.mdx)("strong",{parentName:"p"},"Taint Analysis"),", to identify potential security issues.\nThe Python Static Analyzer feature of Pyre is usually abbreviated to Pysa\n(pronounced like the Leaning Tower of Pisa)."),(0,s.mdx)(o.Z,{videoId:"LDxAczqkBiY",mdxType:"YouTube"}),(0,s.mdx)(h,{mdxType:"Internal"}),(0,s.mdx)("h2",{id:"taint-analysis"},"Taint Analysis"),(0,s.mdx)("p",null,(0,s.mdx)("strong",{parentName:"p"},"Tainted data")," is data that must be treated carefully. Pysa works by tracking\nflows of data from where they originate (sources) to where they terminate in a\ndangerous location (sinks). For example, we might use it to track flows where\nuser-controllable request data flows into an ",(0,s.mdx)("inlineCode",{parentName:"p"},"eval")," call, leading to a remote\ncode execution vulnerability. This analysis is made possible by user-created\nmodels which provide annotations on source code, as well as rules that define\nwhich sources are dangerous for which sinks. Pysa comes with many pre-written\nmodels and rules for builtin and common python libraries."),(0,s.mdx)("p",null,"Pysa propagates taint as operations are performed on tainted data. For example,\nif we start with a tainted integer and perform a number of operations on it, the\nend results will still be tainted:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"x = some_function_that_returns_a_tainted_value() # 'x' is marked as tainted\ny = x + 10\ns = str(x)\nf = f\"Value = {s}\" # 'f' is marked with the same taint 'x' had\n")),(0,s.mdx)("p",null,"Pysa will only analyze the code in the repo that it runs on, as well as code in\ndirectories listed in the ",(0,s.mdx)("inlineCode",{parentName:"p"},"search_path")," of your\n",(0,s.mdx)("a",{parentName:"p",href:"/docs/configuration"},(0,s.mdx)("inlineCode",{parentName:"a"},".pyre_configuration"))," file. It does not see the source of\nyour dependencies. ",(0,s.mdx)("strong",{parentName:"p"},"Just because")," ",(0,s.mdx)("strong",{parentName:"p"},(0,s.mdx)("em",{parentName:"strong"},"you"))," ",(0,s.mdx)("strong",{parentName:"p"},"can see code in your editor\ndoes not mean Pysa has access to that code during analysis.")," Because of this\nlimitation, Pysa makes some simplifying assumptions. If taint flows into a\nfunction Pysa doesn't have the source for, it will assume that the return type\nof that function has the same taint. This helps prevents false negatives, but can\nalso lead to false positives."),(0,s.mdx)("p",null,"When an object is tainted, that means that all attributes of that object are\nalso tainted. Note that this is another source of potential false positives,\nsuch as taint flows that include ",(0,s.mdx)("inlineCode",{parentName:"p"},"some_obj.__class__"),". This means that Pysa\nwill detect all of the following flows:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"x = some_source() # 'x' is marked as tainted\n\nsome_sink(x) # This is detected\nsome_sink(x.some_attribute) # This is also detected\nsome_sink(x.__class__) # This is (unfortunately) also detected\n")),(0,s.mdx)("h2",{id:"configuration"},"Configuration"),(0,s.mdx)("p",null,"Pysa uses two types of files for configuration: a single ",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config")," file,\nand an unlimited number of files with a ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," extension. The ",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config"),"\nfile is a JSON document which stores definitions for ",(0,s.mdx)("em",{parentName:"p"},"sources"),", ",(0,s.mdx)("em",{parentName:"p"},"sinks"),", ",(0,s.mdx)("em",{parentName:"p"},"features"),",\nand ",(0,s.mdx)("em",{parentName:"p"},"rules")," (discussed below). The ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files are model files (also discussed\nbelow) which annotate your code with the ",(0,s.mdx)("em",{parentName:"p"},"sources"),", ",(0,s.mdx)("em",{parentName:"p"},"sinks"),", and ",(0,s.mdx)("em",{parentName:"p"},"features")," defined in\nyour ",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config")," file. Examples of these files can be found in the ",(0,s.mdx)("a",{parentName:"p",href:"https://github.com/facebook/pyre-check/tree/main/stubs/taint"},"Pyre\nrepository"),"."),(0,s.mdx)("p",null,"These files live in the directory configured by ",(0,s.mdx)("inlineCode",{parentName:"p"},"taint_models_path")," in your\n",(0,s.mdx)("inlineCode",{parentName:"p"},".pyre_configuration")," file. Any ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," file found in this folder will be parsed\nby Pysa and the models will be used during the analysis."),(0,s.mdx)("h2",{id:"sources"},"Sources"),(0,s.mdx)("p",null,"Sources are where tainted data originates. They are declared in your\n",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config")," file like this:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-json"},'"sources": [\n    {\n        "name": "Cookies",\n        "comment": "used to annotate cookie sources"\n    }\n]\n')),(0,s.mdx)("p",null,"Models that indicate what is a source are then defined in ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa"),"\nfiles. Sources are declared with the same syntax as ",(0,s.mdx)("a",{parentName:"p",href:"https://docs.python.org/3/library/typing.html"},"type annotations in Python\n3"),". Function return types,\nclass/model attributes, and even entire classes can be declared as sources by\nadding ",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintSource[SOURCE_NAME]")," wherever you would add a python type:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# Function return source\ndef django.http.request.HttpRequest.get_signed_cookie(\n    self,\n    key,\n    default=...,\n    salt=...,\n    max_age=...\n) -> TaintSource[Cookies]: ...\n\n# Class attribute source:\ndjango.http.request.HttpRequest.COOKIES: TaintSource[Cookies]\n")),(0,s.mdx)("p",null,"When tainting an entire class, any return from a method or access of an\nattribute of the class will count as a returning tainted data. The specifics of\nthese model files are discussed further in the Models section."),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# Class source:\nclass BaseException(TaintSource[Exception]): ...\n")),(0,s.mdx)("p",null,"When tainting indexable return types such as ",(0,s.mdx)("inlineCode",{parentName:"p"},"Dict"),"s, ",(0,s.mdx)("inlineCode",{parentName:"p"},"List"),"s, and ",(0,s.mdx)("inlineCode",{parentName:"p"},"Tuple"),"s, the\n",(0,s.mdx)("inlineCode",{parentName:"p"},"ReturnPath")," syntax can be used to only mark a portion of the return type as\ntainted:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},'def applies_to_index.only_applies_to_nested() -> TaintSource[Test, ReturnPath[_[0][1]]]: ...\ndef applies_to_index.only_applies_to_a_key() -> TaintSource[Test, ReturnPath[_["a"]]]: ...\n')),(0,s.mdx)("p",null,"Note that ",(0,s.mdx)("inlineCode",{parentName:"p"},"ReturnPath")," syntax can also be applied to fields of classes and globals,\nwhich can be particularly helpful when annotating dictionaries."),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},'# Source file: a.py\nclass C:\n    dictionary_field = {"text": "will_be_tainted"}\n\n# Model file: models.pysa\na.C.dictionary_field: TaintSource[Test, ReturnPath[_["text"]]]\n')),(0,s.mdx)("p",null,"See ",(0,s.mdx)("a",{parentName:"p",href:"/docs/pysa-advanced#parameter-and-return-path"},"Parameter and Return Path")," for additional information."),(0,s.mdx)("h2",{id:"sinks"},"Sinks"),(0,s.mdx)("p",null,"Sinks are where tainted data terminates. They are declared in your\n",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config")," file like this:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-json"},'"sinks": [\n  {\n    "name": "SQL",\n    "comment": "use to annotate places of SQL injection risk"\n  }\n]\n')),(0,s.mdx)("p",null,"Models that indicate what is a sink are then defined in ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files. Sinks can\nbe added to the same files as sources. Like sources, sinks are declared with the\nsame syntax as ",(0,s.mdx)("a",{parentName:"p",href:"https://docs.python.org/3/library/typing.html"},"type annotations in Python\n3"),". Function parameters, class\nattributes, and even whole classes can be declared as sinks by adding\n",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintSink[SINK_NAME]")," where you would add a python type:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# Function parameter sink\ndef sqlite3.dbapi2.Cursor.execute(self, sql: TaintSink[SQL], parameters): ...\n\n# Attribute sink\nfile_name.ClassName.attribute_name: TaintSink[RemoteCodeExecution]\n")),(0,s.mdx)("p",null,"When tainting an entire class, any flow into a method or attribute of the class\nwill count as a flow to a taint sink. The specifics of these model files are\ndiscussed further in the Models section."),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# Entire class sink\nclass BaseException(TaintSink[Logging]): ...\n")),(0,s.mdx)("h3",{id:"implicit-sinks"},"Implicit Sinks"),(0,s.mdx)("p",null,"Implicit sinks are program expressions that we want to act as sinks, but that\ncannot be specified via taint signatures in ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files.  Currently, only\nconditional tests are supported as implicit sinks. This allows writing rules\nthat track whether a particular source is used in a conditional test\nexpression."),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-json"},'"implicit_sinks": {\n  "conditional_test": [ <your kind> ]\n}\n')),(0,s.mdx)("h2",{id:"rules"},"Rules"),(0,s.mdx)("p",null,"Rules declare which flows from source to sink we are concerned about. They are\ndeclared in your ",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config")," file like this:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-json"},'"rules": [\n  {\n    "name": "SQL injection.",\n    "code": 1,\n    "sources": [ "UserControlled" ],\n    "sinks": [ "SQL" ],\n    "message_format": "Data from [{$sources}] source(s) may reach [{$sinks}] sink(s)"\n  }\n]\n')),(0,s.mdx)("p",null,"Each rule needs a brief ",(0,s.mdx)("inlineCode",{parentName:"p"},"name")," that explains its purpose and a ",(0,s.mdx)("em",{parentName:"p"},"unique")," ",(0,s.mdx)("inlineCode",{parentName:"p"},"code"),".\nThe rule must define a list of one or more ",(0,s.mdx)("inlineCode",{parentName:"p"},"sources"),", which we are concerned\nabout flowing into one or more ",(0,s.mdx)("inlineCode",{parentName:"p"},"sinks"),". ",(0,s.mdx)("inlineCode",{parentName:"p"},"message_format")," can further explain the\nissue. When a flow is detected the ",(0,s.mdx)("inlineCode",{parentName:"p"},"{$sources}")," and ",(0,s.mdx)("inlineCode",{parentName:"p"},"{$sinks}")," variables will be\nreplaced with the name of the specific source(s) and sink(s) that were involved\nin the detected flow."),(0,s.mdx)("h2",{id:"sanitizers"},"Sanitizers"),(0,s.mdx)("p",null,"Sanitizers break a taint flow by removing taint from data. Models that indicate\nsanitizing functions are defined in ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files. Sanitizers can be added to\nthe same files as sources and sinks. Functions are declared as sanitizers by\nadding a special decorator:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# This will remove any taint passing through a function, regardless of whether\n# it is a taint source returned by this function, taint reaching sinks within\n# the function via 'text', or taint propagateing through 'text' to the\n# return value.\n@Sanitize\ndef django.utils.html.escape(text): ...\n")),(0,s.mdx)("p",null,"This annotation is useful in the case of explicit sanitizers such as ",(0,s.mdx)("inlineCode",{parentName:"p"},"escape"),",\nwhich helps prevent cross site scripting (XSS) by escaping HTML characters. The\nannotation is also useful, however, in cases where a function is not intended to\nsanitize inputs, but is known to always return safe data despite touching\ntainted data. One such example could be ",(0,s.mdx)("inlineCode",{parentName:"p"},"hmac.digest(key, msg, digest)"),", which\nreturns sufficiently unpredictable data that the output should no longer be\nconsidered attacker-controlled after passing through."),(0,s.mdx)("p",null,"Sanitizers can also be scoped to only remove taint returned by a function,\npassing through a specific argument, or passing through all arguments."),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# This will remove any taint returned by this function, but allow taint\n# to be passed in to the function via 'argument'. It also prevents taint\n# from propagating from any argument to the return value.\ndef module.sanitize_return(argument) -> Sanitize: ...\n\n# This prevents any taint which passes through 'argument' from reaching a sink within\n# the function, but allows taint which originates within the function to be returned.\ndef module.sanitize_parameter(argument: Sanitize): ...\n\n# This prevents any taint which passes through any parameter from entering the function,\n# but allows taint which originates within the function to be returned. It also prevents\n# taint from propagating from any argument to the return value.\n@Sanitize(Parameters)\ndef module.sanitize_all_parameters(): ...\n\n# This will remove any taint which propagates through any argument to the return\n# value, but allow taint sources to be returned from the function as well as\n# allow taint to reach sinks within the function via any argument.\n@Sanitize(TaintInTaintOut)\ndef module.sanitize_tito(a, b, c): ...\n\n# Same as before, but only for parameter 'b'\ndef module.sanitize_tito_b(a, b: Sanitize[TaintInTaintOut], c): ...\n")),(0,s.mdx)("p",null,"Pysa also supports only sanitizing specific sources or sinks to ensure that the\nsanitizers used for a rule don't have adverse effects on other rules. The syntax\nused is identical to how taint sources and sinks are specified normally:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# Sanitizes only the `UserControlled` source kind.\ndef module.return_not_user_controlled() -> Sanitize[TaintSource[UserControlled]]: ...\n\n# Sanitizes both the `SQL` and `Logging` sinks.\ndef module.sanitizes_sql_and_logging_sinks(\n  flows_to_sql: Sanitize[TaintSink[SQL]],\n  logged_parameter: Sanitize[TaintSink[Logging]],\n): ...\n")),(0,s.mdx)("p",null,"For taint-in-taint-out (TITO) sanitizers, Pysa supports only sanitizing specific\nsources and sinks through TITO:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# With this annotation, whenever `escape(data)` is called, the UserControlled taint of `data`\n# will be sanitized, whereas other taint that might be present on `data` will be preserved.\n@Sanitize(TaintInTaintOut[TaintSource[UserControlled]])\ndef django.utils.html.escape(text): ...\n\n@Sanitize(TaintInTaintOut[TaintSink[SQL, Logging]])\ndef module.sanitize_for_logging_and_sql(): ...\n")),(0,s.mdx)("p",null,"Note that you can use any combination of annotations, i.e sanitizing specific\nsources or specific sinks, on the return value, a specific parameter or all parameters:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python",metastring:"file=source/interprocedural_analyses/taint/test/integration/sanitize.py.pysa start=DOCUMENTATION_RETURN_SANITIZERS_START end=DOCUMENTATION_RETURN_SANITIZERS_END",file:"source/interprocedural_analyses/taint/test/integration/sanitize.py.pysa",start:"DOCUMENTATION_RETURN_SANITIZERS_START",end:"DOCUMENTATION_RETURN_SANITIZERS_END"},"def sanitize.sanitize_return() -> Sanitize: ...\n\ndef sanitize.sanitize_return_no_user_controlled() -> Sanitize[TaintSource[UserControlled]]: ...\n\ndef sanitize.sanitize_return_no_sql() -> Sanitize[TaintSink[SQL]]: ...\n")),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python",metastring:"file=source/interprocedural_analyses/taint/test/integration/sanitize.py.pysa start=DOCUMENTATION_PARAMETER_SPECIFIC_SANITIZERS_START end=DOCUMENTATION_PARAMETER_SPECIFIC_SANITIZERS_END",file:"source/interprocedural_analyses/taint/test/integration/sanitize.py.pysa",start:"DOCUMENTATION_PARAMETER_SPECIFIC_SANITIZERS_START",end:"DOCUMENTATION_PARAMETER_SPECIFIC_SANITIZERS_END"},"def sanitize.sanitize_parameter(x: Sanitize): ...\n\ndef sanitize.sanitize_parameter_all_tito(x: Sanitize[TaintInTaintOut]): ...\n\ndef sanitize.sanitize_parameter_no_user_controlled(x: Sanitize[TaintSource[UserControlled]]): ...\n\ndef sanitize.sanitize_parameter_no_sql(x: Sanitize[TaintSink[SQL]]): ...\n\ndef sanitize.sanitize_parameter_no_rce(x: Sanitize[TaintSink[RemoteCodeExecution]]): ...\n\ndef sanitize.sanitize_parameter_no_user_controlled_tito(x: Sanitize[TaintInTaintOut[TaintSource[UserControlled]]]): ...\n\ndef sanitize.sanitize_parameter_no_sql_tito(x: Sanitize[TaintInTaintOut[TaintSink[SQL]]]): ...\n")),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python",metastring:"file=source/interprocedural_analyses/taint/test/integration/sanitize.py.pysa start=DOCUMENTATION_PARAMETERS_SANITIZERS_START end=DOCUMENTATION_PARAMETERS_SANITIZERS_END",file:"source/interprocedural_analyses/taint/test/integration/sanitize.py.pysa",start:"DOCUMENTATION_PARAMETERS_SANITIZERS_START",end:"DOCUMENTATION_PARAMETERS_SANITIZERS_END"},"@Sanitize(Parameters)\ndef sanitize.sanitize_all_parameters(): ...\n\n@Sanitize(Parameters[TaintInTaintOut])\ndef sanitize.sanitize_all_parameters_all_tito(): ...\n\n@Sanitize(Parameters[TaintSource[UserControlled]])\ndef sanitize.sanitize_all_parameters_no_user_controlled(): ...\n\n@Sanitize(Parameters[TaintSink[SQL]])\ndef sanitize.sanitize_all_parameters_no_sql(): ...\n\n@Sanitize(Parameters[TaintSink[RemoteCodeExecution]])\ndef sanitize.sanitize_all_parameters_no_rce(): ...\n\n@Sanitize(Parameters[TaintInTaintOut[TaintSource[UserControlled]]])\ndef sanitize.sanitize_all_parameters_no_user_controlled_tito(): ...\n\n@Sanitize(Parameters[TaintInTaintOut[TaintSink[SQL]]])\ndef sanitize.sanitize_all_parameters_no_sql_tito(): ...\n\n@Sanitize(Parameters[TaintInTaintOut[TaintSource[Cookies], TaintSink[SQL]]])\ndef sanitize.sanitize_all_parameters_no_cookies_sql_tito(): ...\n")),(0,s.mdx)("p",null,"Attributes can also be marked as sanitizers to remove all taint passing through\nthem:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"django.http.request.HttpRequest.GET: Sanitize\n")),(0,s.mdx)("p",null,"Sanitizing specific sources and sinks can also be used with attributes:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def module.Node.id: Sanitize[TaintSource[UserSecrets]] = ...\ndef module.Node.id: Sanitize[TaintSink[Logging]] = ...\n")),(0,s.mdx)("p",null,"Note that sanitizers come with the risk of losing legitimate taint flows. They\nremove all taint and aren't restricted to a specific rule or individual source\nto sink flows. This means you need to ensure you aren't potentially affecting\nother flows when you add a sanitizer for a flow you care about. For this reason,\nsome of the above sanitizer examples might not be a good idea to use. For example,\nif you are trying to track flows where SQL injection occurs, the ",(0,s.mdx)("inlineCode",{parentName:"p"},"escape")," sanitizer\nremoving all taint kinds would prevent you from seeing any flows where data going\ninto your SQL query happened to be HTML escaped. The best practice with sanitizers,\nthen, is to make them as specific as possible. It's recommended to sanitize\nspecific sources and sinks over using the general ",(0,s.mdx)("inlineCode",{parentName:"p"},"@Sanitize"),", ",(0,s.mdx)("inlineCode",{parentName:"p"},"-> Sanitize")," or\n",(0,s.mdx)("inlineCode",{parentName:"p"},": Sanitize")," annotations."),(0,s.mdx)("h3",{id:"tito-sanitizers-vs-sourcesink-sanitizers"},"TITO Sanitizers vs Source/Sink Sanitizers"),(0,s.mdx)("p",null,"Source/Sink sanitizers are used to sanitize functions belonging to the source/sink trace. Example"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},'def render_string_safe(string: str):\n  safe_strings_list = ["safe", "string", "list"]\n  if string in safe_strings_list:\n    return render(string)\n\ndef render_input_view(request: HttpRequest):\n  user_input = request.GET["user_input"]\n  return render_string_safe(user_input)\n')),(0,s.mdx)("p",null,"Without any sanitizer this code would raise a pysa issue since the UserControlled input is flowing into the ",(0,s.mdx)("inlineCode",{parentName:"p"},"render")," function (imagining that the ",(0,s.mdx)("inlineCode",{parentName:"p"},"render")," function is an XSS sink).\nTo avoid this we can create a model:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def render_string_safe(string: Sanitize[TaintSink[XSS]]): ...\n")),(0,s.mdx)("p",null,"This will instruct pysa to remove the XSS taint on the string parameter in this way even if we have a XSS sink (",(0,s.mdx)("inlineCode",{parentName:"p"},"render"),") inside the ",(0,s.mdx)("inlineCode",{parentName:"p"},"render_string_safe")," function we will not trigger an issue."),(0,s.mdx)("p",null,"TITO Sanitizers instead are used to remove the taint when tainted value is flowing into (TaintIn) a function as a parameter and then it is returned (TaintOut) by the same function."),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def sanitize_string(string: str):\n  return re.sub('[^0-9a-z]+', '*', string)\n\ndef render_input_view(request: HttpRequest):\n  user_input = request.GET[\"user_input\"]\n  safe_str = sanitize_string(user_input)\n  return render(safe_str)\n")),(0,s.mdx)("p",null,"Like in the example before this code would generate a Pysa XSS issue. To avoid this we can create a model:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def sanitize_string(string: Sanitize[TaintInTaintOut[TaintSink[XSS]]]): ...\n")),(0,s.mdx)("p",null,"This will instruct pysa to remove the XSS taint from the value returned by the ",(0,s.mdx)("inlineCode",{parentName:"p"},"sanitize_string")," when a tainted value is passed as ",(0,s.mdx)("inlineCode",{parentName:"p"},"string")," parameter to the ",(0,s.mdx)("inlineCode",{parentName:"p"},"sanitize_string")," function."),(0,s.mdx)("h2",{id:"taint-propagation"},"Taint Propagation"),(0,s.mdx)("p",null,"Sometimes, Pysa is unable to infer that tainted data provided as an argument to a function will be returned by that function. In such cases, Pysa models can be annotated with ",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintInTaintOut[LocalReturn]")," to encode this information for the analysis. This annotation can be applied to any parameter, including ",(0,s.mdx)("inlineCode",{parentName:"p"},"self"),", and is useful in scenarios such as when retrieving a value from a collection containting tainted data:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# This tells Pysa that if a 'dict' contains tainted data, the result\n# of calling 'get' on that dict will also contain tainted data\ndef dict.get(self: TaintInTaintOut[LocalReturn], key, default): ...\n")),(0,s.mdx)("p",null,"Note that ",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintInTaintOut")," (ie. without square brackets) is also accepted and can be used as a short hand for ",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintInTaintOut[LocalReturn]"),". ",(0,s.mdx)("inlineCode",{parentName:"p"},"LocalReturn")," is ony ever ",(0,s.mdx)("em",{parentName:"p"},"required")," when using the ",(0,s.mdx)("inlineCode",{parentName:"p"},"Updates")," syntax below and wanting to preserve the ",(0,s.mdx)("inlineCode",{parentName:"p"},"LocalReturn")," behaviour."),(0,s.mdx)("p",null,"For performance reasons, Pysa does not keep track of when functions place taint into their parameters, such as when a function adds a tainted entry to a list it received (with some notable exceptions for taint assigned to ",(0,s.mdx)("inlineCode",{parentName:"p"},"self")," in a constructor or property). The ",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintInTaintOut[Updates[PARAMETER]]")," annotation can be used to work around Pysa's limitations by telling Pysa that taint will flow the the annotated parameter into the parameter named ",(0,s.mdx)("inlineCode",{parentName:"p"},"PARAMETER"),":"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"# This tells Pysa that if 'dict.update' is called with tainted data,\n# then the 'self' object (ie. the dictionary itself) should then be\n# considered tainted.\ndef dict.update(self, __m: TaintInTaintOut[Updates[self]]): ...\n")),(0,s.mdx)("p",null,"Note that ",(0,s.mdx)("strong",{parentName:"p"},"constructors")," and ",(0,s.mdx)("strong",{parentName:"p"},"property setters")," are treated as if they were returning ",(0,s.mdx)("inlineCode",{parentName:"p"},"self"),". This means you should use ",(0,s.mdx)("inlineCode",{parentName:"p"},"LocalReturn")," instead of ",(0,s.mdx)("inlineCode",{parentName:"p"},"Updates[self]")," when writing models those. For instance:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def MyClass.__init__(self, argument: TaintInTaintOut[LocalReturn]): ...\n@foo.setter\ndef MyClass.foo(self, value: TaintInTaintOut[LocalReturn]): ...\n")),(0,s.mdx)("p",null,(0,s.mdx)("a",{parentName:"p",href:"/docs/pysa-features"},"Feature annotations")," may also be placed inside the ",(0,s.mdx)("inlineCode",{parentName:"p"},"[]")," blocks of ",(0,s.mdx)("inlineCode",{parentName:"p"},"TaintInTaintOut[...]")," annotations."),(0,s.mdx)("h2",{id:"features"},"Features"),(0,s.mdx)("p",null,"Feature annotations are also placed in your ",(0,s.mdx)("inlineCode",{parentName:"p"},"taint.config")," and ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files.\nThis is a larger topic and will be covered in detail on ",(0,s.mdx)("a",{parentName:"p",href:"/docs/pysa-features"},"its own page"),"."),(0,s.mdx)("h2",{id:"model-files"},"Model files"),(0,s.mdx)("h3",{id:"usage"},"Usage"),(0,s.mdx)("p",null,"By default, Pysa computes an inferred model for each function and combines it\nwith any declared models in ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files (of which there can be more than one).\nThe union of these models and their annotations will be used. For example,\ncookies are both user controlled and potentially sensitive to log, and Pysa\nallows us apply two different annotations to them:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"django.http.request.HttpRequest.COOKIES: TaintSource[UserControlled]\ndjango.http.request.HttpRequest.COOKIES: TaintSource[Cookies]\n")),(0,s.mdx)("h3",{id:"requirements-and-features"},"Requirements and Features"),(0,s.mdx)("h4",{id:"fully-qualified-names"},"Fully qualified names"),(0,s.mdx)("p",null,"Any declarations in ",(0,s.mdx)("inlineCode",{parentName:"p"},".pysa")," files must use the fully qualified name for the\nfunction/attribute they are attempting to annotate. You can usually find the\nfully qualified name for a type by looking at how it is imported, however, it's\nimportant to note that fully qualified names correspond to where something is\ndeclared, not necessarily where it is imported from. For example, you can import\n",(0,s.mdx)("inlineCode",{parentName:"p"},"HttpRequest")," directly from the ",(0,s.mdx)("inlineCode",{parentName:"p"},"django.http")," module, even though it is defined in\n",(0,s.mdx)("inlineCode",{parentName:"p"},"django.http.request"),". If you wanted to taint an attribute of ",(0,s.mdx)("inlineCode",{parentName:"p"},"HttpRequest"),",\nyou would need to use the module in which it was defined:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"django.http.request.HttpRequest.GET: TaintSource[UserControlled]\n")),(0,s.mdx)("h4",{id:"matching-signatures"},"Matching signatures"),(0,s.mdx)("p",null,"The signature of any modeled function needs to match the signature of the\nfunction, as seen by Pyre. Note that Pyre doesn't always see the definition of\nthe functions directly. If ",(0,s.mdx)("a",{parentName:"p",href:"https://www.python.org/dev/peps/pep-0484/#stub-files"},(0,s.mdx)("inlineCode",{parentName:"a"},".pyi")," stub\nfiles")," are present, Pyre\nwill use the signatures from those files, rather than the actual signature from\nthe function definition in your or your dependencies' code. See the ",(0,s.mdx)("a",{parentName:"p",href:"/docs/types-in-python"},"Gradual\nTyping page")," for more info about these ",(0,s.mdx)("inlineCode",{parentName:"p"},".pyi")," stubs."),(0,s.mdx)("p",null,"This matching signature requirement means that all parameters being modelled must\nbe named identically to the parameters in the corresponding code or ",(0,s.mdx)("inlineCode",{parentName:"p"},".pyi")," file.\nUnmodelled parameters, ",(0,s.mdx)("inlineCode",{parentName:"p"},"*args"),", and ",(0,s.mdx)("inlineCode",{parentName:"p"},"**kwargs")," may be included, but\nare not required. When copying parameters to your model, all type information\nmust be removed, and all default values must be elided (see below)."),(0,s.mdx)("p",null,"If a function includes an ",(0,s.mdx)("inlineCode",{parentName:"p"},"*")," that indicates ",(0,s.mdx)("a",{parentName:"p",href:"https://www.python.org/dev/peps/pep-3102/"},"keyword only\nparameters"),", or a ",(0,s.mdx)("inlineCode",{parentName:"p"},"/")," that indicates\n",(0,s.mdx)("a",{parentName:"p",href:"https://www.python.org/dev/peps/pep-0570/"},"positional-only parameters"),", then\nthat may be included in your model. Note that unlike when modeling named parameters,\nyou need to include all positional only parameters the model so that Pysa knows what\nposition is being tainted."),(0,s.mdx)("p",null,"For example, ",(0,s.mdx)("inlineCode",{parentName:"p"},"urllib.request.urlopen")," has the following signature:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def urlopen(url, data=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, *, cafile=None,\n            capath=None, cadefault=False, context=None):\n")),(0,s.mdx)("p",null,"Given that signature, either of the following models are acceptable:"),(0,s.mdx)("pre",null,(0,s.mdx)("code",{parentName:"pre",className:"language-python"},"def urllib.request.urlopen(url: TaintSink[HTTPClientRequest], data,\n                           timeout, *, cafile, capath,\n                           cadefault, context): ...\ndef urllib.request.urlopen(url: TaintSink[HTTPClientRequest]): ...\n")),(0,s.mdx)("p",null,"Pysa will complain if the signature of your model doesn't match the\nimplementation. When working with functions defined outside your project, where\nyou don't directly see the source, you can use ",(0,s.mdx)("a",{parentName:"p",href:"/docs/querying-pyre"},(0,s.mdx)("inlineCode",{parentName:"a"},"pyre query")),"\nwith the ",(0,s.mdx)("inlineCode",{parentName:"p"},"signature")," argument to have Pysa dump it's internal model of a\nfunction, so you know exactly how to write your model."),(0,s.mdx)("h4",{id:"eliding"},"Eliding"),(0,s.mdx)("p",null,"As you can see from the above examples, unmodelled parameters and function bodies can\nboth be elided with ",(0,s.mdx)("inlineCode",{parentName:"p"},"..."),". Additionally, type annotations ",(0,s.mdx)("em",{parentName:"p"},"must")," be entirely\nomitted (not replaced with ",(0,s.mdx)("inlineCode",{parentName:"p"},"..."),"), even when present on the declaration of the\nfunction. This is done to make parsing taint annotations unambiguous."),(0,s.mdx)(f,{mdxType:"FbInternalOnly"},(0,s.mdx)("h2",{id:"next-steps"},"Next Steps"),(0,s.mdx)("p",null,"Ready to start writing some models? Check out our docs on the\n",(0,s.mdx)("a",{parentName:"p",href:"fb/pysa_shipping_rules_models_internal.md"},"end-to-end process of shipping pysa models."))))}y.isMDXComponent=!0}}]);