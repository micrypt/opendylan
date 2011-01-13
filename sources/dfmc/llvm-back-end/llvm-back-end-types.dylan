Module: dfmc-llvm-back-end
Copyright:    Original Code is Copyright (c) 1995-2004 Functional Objects, Inc.
              Additional code is Copyright 2009-2010 Gwydion Dylan Maintainers
              All rights reserved.
License:      See License.txt in this distribution for details.
Warranty:     Distributed WITHOUT WARRANTY OF ANY KIND

// LLVM type for object pointers, and for tagged direct objects
// (integers and characters)
define constant $llvm-object-pointer-type :: <llvm-type> = $llvm-i8*-type;


/// Memoized pointer types

define inline method llvm-pointer-to
    (back-end :: <llvm-back-end>, type :: <llvm-type>)
 => (pointer-type :: <llvm-pointer-type>);
  let type = llvm-type-forward(type);
  element(back-end.%pointer-to-table, type, default: #f)
    | (element(back-end.%pointer-to-table, type)
         := make(<llvm-pointer-type>, pointee: type))
end method;


/// Built-in types

define method initialize-type-table
    (back-end :: <llvm-back-end>) => ()
  let t = back-end.%type-table;

  // Word-size integer
  t["iWord"]
    := make(<llvm-integer-type>, width: back-end-word-size(back-end) * 8);

  // Double-word-size integer
  t["iDoubleWord"]
    := make(<llvm-integer-type>, width: back-end-word-size(back-end) * 8 * 2);

  // MM Wrapper
  let placeholder = make(<llvm-opaque-type>);
  t["Wrapper"]
    := make(<llvm-struct-type>,
            elements: vector(// Wrapper-Wrapper
                             placeholder,
                             // Class pointer
                             $llvm-object-pointer-type,
                             // Subtype mask (as a tagged fixed <integer>)
                             $llvm-object-pointer-type,
                             // Fixed part length and format
                             t["iWord"],
                             // Variable part length and format
                             t["iWord"],
                             // Pattern vector size (as a tagged <integer>)
                             $llvm-object-pointer-type,
                             // (Empty) Pattern vector
                             make(<llvm-array-type>,
                                  size: 0,
                                  element-type: t["iWord"])));
  placeholder.llvm-placeholder-type-forward
    := llvm-pointer-to(back-end, t["Wrapper"]);
end method;

// Register each of the built-in types in a new module's type symbol table
define method llvm-register-types
    (back-end :: <llvm-back-end>, module :: <llvm-module>) => ()
  for (type keyed-by name in back-end.%type-table)
    module.llvm-type-table[name] := type;
  end for;
end method;


/// Raw type mappings

// Register LLVM types for each of the defined <&raw-type> instances
define method initialize-raw-type-table
    (back-end :: <llvm-back-end>) => ();
  let t = back-end.%type-table;

  local
    method register-raw-type
        (type-name :: <symbol>, type :: <llvm-type>) => ();
      let raw-type = dylan-value(type-name);
      back-end.%raw-type-table[raw-type] := type;
    end method;

  // FIXME
  let llvm-long-double-type = make(<llvm-primitive-type>, kind: #"X86_FP80");
  
  register-raw-type(#"<raw-c-signed-char>",        $llvm-i8-type);
  register-raw-type(#"<raw-c-unsigned-char>",      $llvm-i8-type);
  register-raw-type(#"<raw-c-signed-short>",       $llvm-i16-type);
  register-raw-type(#"<raw-c-unsigned-short>",     $llvm-i16-type);
  register-raw-type(#"<raw-c-signed-int>",         $llvm-i32-type);
  register-raw-type(#"<raw-c-unsigned-int>",       $llvm-i32-type);
  register-raw-type(#"<raw-c-signed-long>",        t["iWord"]);
  register-raw-type(#"<raw-c-unsigned-long>",      t["iWord"]);
  register-raw-type(#"<raw-c-signed-long-long>",   $llvm-i64-type);
  register-raw-type(#"<raw-c-unsigned-long-long>", $llvm-i64-type);
  register-raw-type(#"<raw-c-float>",              $llvm-float-type);
  register-raw-type(#"<raw-c-double>",             $llvm-double-type);
  register-raw-type(#"<raw-c-long-double>",        llvm-long-double-type);
  register-raw-type(#"<raw-c-void>",               $llvm-void-type);
  register-raw-type(#"<raw-c-pointer>",            $llvm-i8*-type);
  register-raw-type(#"<raw-boolean>",              $llvm-i8-type);
  register-raw-type(#"<raw-byte-character>",       $llvm-i8-type);
  register-raw-type(#"<raw-unicode-character>",    $llvm-i32-type);
  register-raw-type(#"<raw-byte>",                 $llvm-i8-type);
  register-raw-type(#"<raw-double-byte>",          $llvm-i16-type);
  register-raw-type(#"<raw-byte-string>",          $llvm-i8*-type);
  register-raw-type(#"<raw-integer>",              t["iWord"]);
  register-raw-type(#"<raw-single-float>",         $llvm-float-type);
  register-raw-type(#"<raw-machine-word>",         t["iWord"]);
  register-raw-type(#"<raw-double-float>",         $llvm-double-type);
  register-raw-type(#"<raw-extended-float>",       llvm-long-double-type);
  register-raw-type(#"<raw-pointer>",              $llvm-i8*-type);
  register-raw-type(#"<raw-address>",              t["iWord"]);
end method;


/// Object types

define method llvm-object-type
    (back-end :: <llvm-back-end>, o)
 => (type :: <llvm-type>);
  let class = o.&object-class;
  ^ensure-slots-initialized(class);
  let rslotd = class.^repeated-slot-descriptor; 
  let repeated-size = rslotd & ^slot-value(o, ^size-slot-descriptor(rslotd));
  llvm-class-type(back-end, class, repeated-size: repeated-size)
end method;

// Compute the type for representing instances of a class as an LLVM struct;
// Classes with repeated slot definitions require one type definition for
// each size encountered.
define method llvm-class-type
    (back-end :: <llvm-back-end>, class :: <&class>,
     #key repeated-size :: false-or(<integer>) = #f)
 => (type :: <llvm-type>);
  let base-name = emit-name-internal(back-end, #f, class);
  let name
    = if (repeated-size & repeated-size > 0)
        format-to-string("ST.%s_%d", base-name, repeated-size)
      else
        concatenate("ST.", base-name)
      end if;

  // Locate the memoized type, if any, with that name
  let module = back-end.llvm-builder-module;
  let type-table = module.llvm-type-table;
  let type = element(type-table, name, default: #f);
  if (type)
    type
  else
    let islots = class.^instance-slot-descriptors;
    let rslotd = class.^repeated-slot-descriptor; 
    let elements
      = make(<simple-object-vector>,
             size: if (rslotd) islots.size + 2 else islots.size + 1 end);

    // The first element is always the wrapper pointer
    elements[0] := llvm-pointer-to(back-end, type-table["Wrapper"]);

    // One element for each slot
    for (instance-slot in islots, index from 1)
      elements[index]
        := llvm-reference-type(back-end, instance-slot.^slot-type);
    finally
      if (rslotd)
        // One array element for the repeated slot
        let repeated-slot-type = rslotd.^slot-type;
        let repeated-type
          = if (repeated-slot-type == dylan-value(#"<byte-character>"))
              $llvm-i8-type
            else
              llvm-reference-type(back-end, repeated-slot-type);
            end if;
        elements[index] := make(<llvm-array-type>,
                                size: repeated-size | 0,
                                element-type: repeated-type);
      end if;
    end for;

    element(type-table, name) := make(<llvm-struct-type>, elements: elements)
  end if
end method;

// Uses of raw types utilize the registered LLVM type for the raw type
define method llvm-reference-type
    (back-end :: <llvm-back-end>, o :: <&raw-type>)
 => (type :: <llvm-type>);
  back-end.%raw-type-table[o]
end method;

// References to most objects use the object pointer type
define method llvm-reference-type
    (back-end :: <llvm-back-end>, o)
 => (type :: <llvm-type>);
  $llvm-object-pointer-type
end method;


/// Code types

// Lambdas (internal entry points)

define method llvm-signature-types
    (back-end :: <llvm-back-end>, o :: <&iep>,
     sig-spec :: <signature-spec>, sig :: <&signature>)
 => (parameter-types :: <sequence>);
  let parameter-types = make(<stretchy-object-vector>);

  // Required arguments
  for (type in ^signature-required(sig))
    add!(parameter-types, llvm-reference-type(back-end, type));
  end for;
  // Optional arguments
  if (^signature-optionals?(sig))
    add!(parameter-types, $llvm-object-pointer-type);
  end if;
  // Keyword arguments
  for (spec in spec-argument-key-variable-specs(sig-spec))
    add!(parameter-types, $llvm-object-pointer-type);
  end for;
  parameter-types
end method;

define method llvm-dynamic-signature-types
    (back-end :: <llvm-back-end>, o :: <&iep>, sig-spec :: <signature-spec>)
 => (parameter-types :: <sequence>);
  let parameter-types = make(<stretchy-object-vector>);

  // Required arguments
  for (spec in spec-argument-required-variable-specs(sig-spec))
    add!(parameter-types, $llvm-object-pointer-type);
  end for;
  // Optional arguments
  if (spec-argument-optionals?(sig-spec))
    add!(parameter-types, $llvm-object-pointer-type);
  end if;
  for (spec in spec-argument-key-variable-specs(sig-spec))
    add!(parameter-types, $llvm-object-pointer-type);
  end for;
  
  parameter-types
end method;

// Function type for an Internal Entry Point function
define method llvm-lambda-type
    (back-end :: <llvm-back-end>, o :: <&iep>)
 => (type :: <llvm-function-type>);
  let fun = function(o);
  let signature = ^function-signature(fun);

  // Compute return type
  let return-type
    = if (~signature | spec-value-rest?(signature-spec(fun)))
        $llvm-object-pointer-type
      else
        llvm-reference-type
          (back-end, 
           first(^signature-values(signature),
                 default: dylan-value(#"<object>")))
      end if;
  // Compute parameter types
  let parameter-types
    = if (signature)
        llvm-signature-types(back-end, o, signature-spec(fun), signature)
      else
        llvm-dynamic-signature-types(back-end, o, signature-spec(fun))
      end if;
  make(<llvm-function-type>,
       return-type: return-type,
       parameter-types: parameter-types,
       varargs?: #f)
end method;

// Shared generic entry points

define method llvm-entry-point-type
    (back-end :: <llvm-back-end>, o :: <&shared-entry-point>)
 => (type :: <llvm-function-type>);
  let module = back-end.llvm-builder-module;
  let base-name
    = emit-name-internal(back-end, back-end.llvm-builder-module, o);
  let name = concatenate("EPFN.", base-name);
  let type-table = module.llvm-type-table;
  let type = element(type-table, name, default: #f);
  if (type)
    type
  else
    // FIXME
    element(type-table, name)
      := make(<llvm-function-type>,
              return-type: $llvm-object-pointer-type,
              parameter-types: #(),
              varargs?: #t)
  end if
end method;