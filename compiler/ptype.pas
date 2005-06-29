{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Does parsing types for Free Pascal

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}
unit ptype;

{$i fpcdefs.inc}

interface

    uses
       globtype,symtype;

    const
       { forward types should only be possible inside a TYPE statement }
       typecanbeforward : boolean = false;

    var
       { hack, which allows to use the current parsed }
       { object type as function argument type  }
       testcurobject : byte;
       curobjectname : stringid;

    { reads a string, file type or a type id and returns a name and }
    { tdef }
    procedure single_type(var tt:ttype;isforwarddef:boolean);

    procedure read_type(var tt:ttype;const name : stringid;parseprocvardir:boolean);

    { reads a type definition }
    { to a appropriating tdef, s gets the name of   }
    { the type to allow name mangling          }
    procedure id_type(var tt : ttype;isforwarddef:boolean);


implementation

    uses
       { common }
       cutils,
       { global }
       globals,tokens,verbose,
       systems,
       { target }
       paramgr,
       { symtable }
       symconst,symbase,symdef,symsym,symtable,
       defutil,defcmp,
       { pass 1 }
       node,
       nmat,nadd,ncal,nset,ncnv,ninl,ncon,nld,nflw,
       { parser }
       scanner,
       pbase,pexpr,pdecsub,pdecvar,pdecobj;


    procedure id_type(var tt : ttype;isforwarddef:boolean);
    { reads a type definition }
    { to a appropriating tdef, s gets the name of   }
    { the type to allow name mangling          }
      var
        is_unit_specific : boolean;
        pos : tfileposinfo;
        srsym : tsym;
        srsymtable : tsymtable;
        s,sorg : stringid;
      begin
         s:=pattern;
         sorg:=orgpattern;
         pos:=akttokenpos;
         { classes can be used also in classes }
         if (curobjectname=pattern) and is_class_or_interface(aktobjectdef) then
           begin
              tt.setdef(aktobjectdef);
              consume(_ID);
              exit;
           end;
         { objects can be parameters }
         if (testcurobject=2) and (curobjectname=pattern) then
           begin
              tt.setdef(aktobjectdef);
              consume(_ID);
              exit;
           end;
         { try to load the symbol to see if it's a unitsym. Use the
           special searchsym_type that ignores records,objects and
           parameters }
         is_unit_specific:=false;
         searchsym_type(s,srsym,srsymtable);
         consume(_ID);
         if assigned(srsym) and
            (srsym.typ=unitsym) then
           begin
              is_unit_specific:=true;
              consume(_POINT);
              if not(srsym.owner.symtabletype in [staticsymtable,globalsymtable]) then
                internalerror(200501155);
              { only allow unit.symbol access if the name was
                found in the current module }
              if srsym.owner.iscurrentunit then
               begin
                 srsym:=searchsymonlyin(tunitsym(srsym).unitsymtable,pattern);
                 pos:=akttokenpos;
                 s:=pattern;
               end
              else
               srsym:=nil;
              consume(_ID);
           end;
         { Types are first defined with an error def before assigning
           the real type so check if it's an errordef. if so then
           give an error. Only check for typesyms in the current symbol
           table as forwarddef are not resolved directly }
         if assigned(srsym) and
            (srsym.typ=typesym) and
            (srsym.owner=symtablestack) and
            (ttypesym(srsym).restype.def.deftype=errordef) then
          begin
            Message1(type_e_type_is_not_completly_defined,ttypesym(srsym).realname);
            tt:=generrortype;
            exit;
          end;
         { are we parsing a possible forward def ? }
         if isforwarddef and
            not(is_unit_specific) then
          begin
            tt.setdef(tforwarddef.create(s,pos));
            exit;
          end;
         { unknown sym ? }
         if not assigned(srsym) then
          begin
            Message1(sym_e_id_not_found,sorg);
            tt:=generrortype;
            exit;
          end;
         { type sym ? }
         if (srsym.typ<>typesym) then
          begin
            Message(type_e_type_id_expected);
            tt:=generrortype;
            exit;
          end;
         { Give an error when referring to an errordef }
         if (ttypesym(srsym).restype.def.deftype=errordef) then
          begin
            Message(sym_e_error_in_type_def);
            tt:=generrortype;
            exit;
          end;
         { Use the definitions for current unit, because
           they can be refered from the parameters and symbols are not
           loaded at that time. Only write the definition when the
           symbol is the real owner of the definition (not a redefine) }
         if (ttypesym(srsym).owner.symtabletype in [staticsymtable,globalsymtable]) and
            ttypesym(srsym).owner.iscurrentunit and
            (
             (ttypesym(srsym).restype.def.typesym=nil) or
             (srsym=ttypesym(srsym).restype.def.typesym)
            ) then
          tt.setdef(ttypesym(srsym).restype.def)
         else
          tt.setsym(srsym);
      end;


    procedure single_type(var tt:ttype;isforwarddef:boolean);
       var
         t2 : ttype;
       begin
          case token of
            _STRING:
              string_dec(tt);
            _FILE:
              begin
                 consume(_FILE);
                 if token=_OF then
                   begin
                      consume(_OF);
                      single_type(t2,false);
                      tt.setdef(tfiledef.createtyped(t2));
                   end
                 else
                   tt:=cfiletype;
              end;
            _ID:
              id_type(tt,isforwarddef);
            else
              begin
                message(type_e_type_id_expected);
                tt:=generrortype;
              end;
         end;
      end;

    { reads a record declaration }
    function record_dec : tdef;

      var
         symtable : tsymtable;
         storetypecanbeforward : boolean;
         old_object_option : tsymoptions;
      begin
         { create recdef }
         symtable:=trecordsymtable.create(aktpackrecords);
         record_dec:=trecorddef.create(symtable);
         { update symtable stack }
         symtable.next:=symtablestack;
         symtablestack:=symtable;
         { parse record }
         consume(_RECORD);
         old_object_option:=current_object_option;
         current_object_option:=[sp_public];
         storetypecanbeforward:=typecanbeforward;
         { for tp7 don't allow forward types }
         if m_tp7 in aktmodeswitches then
           typecanbeforward:=false;
         read_var_decs(true,false,false);
         consume(_END);
         typecanbeforward:=storetypecanbeforward;
         current_object_option:=old_object_option;
         { make the record size aligned }
         trecordsymtable(symtablestack).addalignmentpadding;
         { restore symtable stack }
         symtablestack:=symtable.next;
      end;


    { reads a type definition and returns a pointer to it }
    procedure read_type(var tt : ttype;const name : stringid;parseprocvardir:boolean);
      var
        pt : tnode;
        tt2 : ttype;
        aktenumdef : tenumdef;
        ap : tarraydef;
        s : stringid;
        l,v : TConstExprInt;
        oldaktpackrecords : longint;
        defpos,storepos : tfileposinfo;

        procedure expr_type;
        var
           pt1,pt2 : tnode;
           lv,hv   : TConstExprInt;
        begin
           { use of current parsed object ? }
           if (token=_ID) and (testcurobject=2) and (curobjectname=pattern) then
             begin
                consume(_ID);
                tt.setdef(aktobjectdef);
                exit;
             end;
           { classes can be used also in classes }
           if (curobjectname=pattern) and is_class_or_interface(aktobjectdef) then
             begin
                tt.setdef(aktobjectdef);
                consume(_ID);
                exit;
             end;
           { we can't accept a equal in type }
           pt1:=comp_expr(not(ignore_equal));
           if (token=_POINTPOINT) then
             begin
               consume(_POINTPOINT);
               { get high value of range }
               pt2:=comp_expr(not(ignore_equal));
               { make both the same type or give an error. This is not
                 done when both are integer values, because typecasting
                 between -3200..3200 will result in a signed-unsigned
                 conflict and give a range check error (PFV) }
               if not(is_integer(pt1.resulttype.def) and is_integer(pt2.resulttype.def)) then
                 inserttypeconv(pt1,pt2.resulttype);
               { both must be evaluated to constants now }
               if (pt1.nodetype=ordconstn) and
                  (pt2.nodetype=ordconstn) then
                 begin
                   lv:=tordconstnode(pt1).value;
                   hv:=tordconstnode(pt2).value;
                   { Check bounds }
                   if hv<lv then
                     Message(parser_e_upper_lower_than_lower)
                   else
                     begin
                       { All checks passed, create the new def }
                       case pt1.resulttype.def.deftype of
                         enumdef :
                           tt.setdef(tenumdef.create_subrange(tenumdef(pt1.resulttype.def),lv,hv));
                         orddef :
                           begin
                             if is_char(pt1.resulttype.def) then
                               tt.setdef(torddef.create(uchar,lv,hv))
                             else
                               if is_boolean(pt1.resulttype.def) then
                                 tt.setdef(torddef.create(bool8bit,l,hv))
                               else
                                 tt.setdef(torddef.create(range_to_basetype(lv,hv),lv,hv));
                           end;
                       end;
                     end;
                 end
               else
                 Message(sym_e_error_in_type_def);
               pt2.free;
             end
           else
             begin
               { a simple type renaming }
               if (pt1.nodetype=typen) then
                 tt:=ttypenode(pt1).resulttype
               else
                 Message(sym_e_error_in_type_def);
             end;
           pt1.free;
        end;

        procedure array_dec;
        var
          lowval,
          highval   : aint;
          arraytype : ttype;
          ht        : ttype;

          procedure setdefdecl(const t:ttype);
          begin
            case t.def.deftype of
              enumdef :
                begin
                  lowval:=tenumdef(t.def).min;
                  highval:=tenumdef(t.def).max;
                  if (m_fpc in aktmodeswitches) and
                     (tenumdef(t.def).has_jumps) then
                   Message(type_e_array_index_enums_with_assign_not_possible);
                  arraytype:=t;
                end;
              orddef :
                begin
                  if torddef(t.def).typ in [uchar,
                    u8bit,u16bit,
                    s8bit,s16bit,s32bit,
{$ifdef cpu64bit}
                    u32bit,s64bit,
{$endif cpu64bit}
                    bool8bit,bool16bit,bool32bit,
                    uwidechar] then
                    begin
                       lowval:=torddef(t.def).low;
                       highval:=torddef(t.def).high;
                       arraytype:=t;
                    end
                  else
                    Message1(parser_e_type_cant_be_used_in_array_index,t.def.gettypename);
                end;
              else
                Message(sym_e_error_in_type_def);
            end;
          end;

        begin
           consume(_ARRAY);
           { open array? }
           if token=_LECKKLAMMER then
             begin
                consume(_LECKKLAMMER);
                { defaults }
                arraytype:=generrortype;
                lowval:=low(aint);
                highval:=high(aint);
                tt.reset;
                repeat
                  { read the expression and check it, check apart if the
                    declaration is an enum declaration because that needs to
                    be parsed by readtype (PFV) }
                  if token=_LKLAMMER then
                   begin
                     read_type(ht,'',true);
                     setdefdecl(ht);
                   end
                  else
                   begin
                     pt:=expr;
                     if pt.nodetype=typen then
                      setdefdecl(pt.resulttype)
                     else
                       begin
                          if (pt.nodetype=rangen) then
                           begin
                             if (trangenode(pt).left.nodetype=ordconstn) and
                                (trangenode(pt).right.nodetype=ordconstn) then
                              begin
                                { make both the same type or give an error. This is not
                                  done when both are integer values, because typecasting
                                  between -3200..3200 will result in a signed-unsigned
                                  conflict and give a range check error (PFV) }
                                if not(is_integer(trangenode(pt).left.resulttype.def) and is_integer(trangenode(pt).left.resulttype.def)) then
                                  inserttypeconv(trangenode(pt).left,trangenode(pt).right.resulttype);
                                lowval:=tordconstnode(trangenode(pt).left).value;
                                highval:=tordconstnode(trangenode(pt).right).value;
                                if highval<lowval then
                                 begin
                                   Message(parser_e_array_lower_less_than_upper_bound);
                                   highval:=lowval;
                                 end;
                                if is_integer(trangenode(pt).left.resulttype.def) then
                                  range_to_type(lowval,highval,arraytype)
                                else
                                  arraytype:=trangenode(pt).left.resulttype;
                              end
                             else
                              Message(type_e_cant_eval_constant_expr);
                           end
                          else
                           Message(sym_e_error_in_type_def)
                       end;
                     pt.free;
                   end;

                { create arraydef }
                  if not assigned(tt.def) then
                   begin
                     ap:=tarraydef.create(lowval,highval,arraytype);
                     tt.setdef(ap);
                   end
                  else
                   begin
                     ap.elementtype.setdef(tarraydef.create(lowval,highval,arraytype));
                     ap:=tarraydef(ap.elementtype.def);
                   end;

                  if token=_COMMA then
                    consume(_COMMA)
                  else
                    break;
                until false;
                consume(_RECKKLAMMER);
             end
           else
             begin
                ap:=tarraydef.create(0,-1,s32inttype);
                ap.IsDynamicArray:=true;
                tt.setdef(ap);
             end;
           consume(_OF);
           read_type(tt2,'',true);
           { if no error, set element type }
           if assigned(ap) then
             ap.setelementtype(tt2);
        end;

      var
        p  : tnode;
        pd : tabstractprocdef;
        is_func,
        enumdupmsg : boolean;
        newtype : ttypesym;
        oldlocalswitches : tlocalswitches;
      begin
         tt.reset;
         case token of
            _STRING,_FILE:
              begin
                single_type(tt,false);
              end;
           _LKLAMMER:
              begin
                consume(_LKLAMMER);
                { allow negativ value_str }
                l:=-1;
                enumdupmsg:=false;
                aktenumdef:=tenumdef.create;
                repeat
                  s:=orgpattern;
                  defpos:=akttokenpos;
                  consume(_ID);
                  { only allow assigning of specific numbers under fpc mode }
                  if not(m_tp7 in aktmodeswitches) and
                     (
                      { in fpc mode also allow := to be compatible
                        with previous 1.0.x versions }
                      ((m_fpc in aktmodeswitches) and
                       try_to_consume(_ASSIGNMENT)) or
                      try_to_consume(_EQUAL)
                     ) then
                    begin
                       oldlocalswitches:=aktlocalswitches;
                       include(aktlocalswitches,cs_allow_enum_calc);
                       p:=comp_expr(true);
                       aktlocalswitches:=oldlocalswitches;
                       if (p.nodetype=ordconstn) then
                        begin
                          { we expect an integer or an enum of the
                            same type }
                          if is_integer(p.resulttype.def) or
                             is_char(p.resulttype.def) or
                             equal_defs(p.resulttype.def,aktenumdef) then
                           v:=tordconstnode(p).value
                          else
                           IncompatibleTypes(p.resulttype.def,s32inttype.def);
                        end
                       else
                        Message(parser_e_illegal_expression);
                       p.free;
                       { please leave that a note, allows type save }
                       { declarations in the win32 units ! }
                       if (v<=l) and (not enumdupmsg) then
                        begin
                          Message(parser_n_duplicate_enum);
                          enumdupmsg:=true;
                        end;
                       l:=v;
                    end
                  else
                    inc(l);
                  storepos:=akttokenpos;
                  akttokenpos:=defpos;
                  constsymtable.insert(tenumsym.create(s,aktenumdef,l));
                  akttokenpos:=storepos;
                until not try_to_consume(_COMMA);
                tt.setdef(aktenumdef);
                consume(_RKLAMMER);
              end;
            _ARRAY:
              begin
                array_dec;
              end;
            _SET:
              begin
                consume(_SET);
                consume(_OF);
                read_type(tt2,'',true);
                if assigned(tt2.def) then
                 begin
                   case tt2.def.deftype of
                     { don't forget that min can be negativ  PM }
                     enumdef :
                       if tenumdef(tt2.def).min>=0 then
                        // !! tt.setdef(tsetdef.create(tt2,tenumdef(tt2.def).min,tenumdef(tt2.def).max))
                        tt.setdef(tsetdef.create(tt2,tenumdef(tt2.def).max))
                       else
                        Message(sym_e_ill_type_decl_set);
                     orddef :
                       begin
                         case torddef(tt2.def).typ of
                           uchar :
                             //!!! tt.setdef(tsetdef.create(tt2,0,255));
                             tt.setdef(tsetdef.create(tt2,255));
                           u8bit,u16bit,u32bit,
                           s8bit,s16bit,s32bit :
                             begin
                               if (torddef(tt2.def).low>=0) then
                                 // !! tt.setdef(tsetdef.create(tt2,torddef(tt2.def).low,torddef(tt2.def).high))
                                 tt.setdef(tsetdef.create(tt2,torddef(tt2.def).high))
                               else
                                Message(sym_e_ill_type_decl_set);
                             end;
                           else
                             Message(sym_e_ill_type_decl_set);
                         end;
                       end;
                     else
                       Message(sym_e_ill_type_decl_set);
                   end;
                 end
                else
                 tt:=generrortype;
              end;
           _CARET:
              begin
                consume(_CARET);
                single_type(tt2,typecanbeforward);
                tt.setdef(tpointerdef.create(tt2));
              end;
            _RECORD:
              begin
                tt.setdef(record_dec);
              end;
            _PACKED:
              begin
                consume(_PACKED);
                if token=_ARRAY then
                  array_dec
                else
                  begin
                    oldaktpackrecords:=aktpackrecords;
                    aktpackrecords:=1;
                    if token in [_CLASS,_OBJECT] then
                      tt.setdef(object_dec(name,nil))
                    else
                      tt.setdef(record_dec);
                    aktpackrecords:=oldaktpackrecords;
                  end;
              end;
            _CLASS,
            _CPPCLASS,
            _INTERFACE,
            _OBJECT:
              begin
                tt.setdef(object_dec(name,nil));
              end;
            _PROCEDURE,
            _FUNCTION:
              begin
                is_func:=(token=_FUNCTION);
                consume(token);
                pd:=tprocvardef.create(normal_function_level);
                if token=_LKLAMMER then
                  parse_parameter_dec(pd);
                if is_func then
                 begin
                   consume(_COLON);
                   single_type(pd.rettype,false);
                 end;
                if token=_OF then
                  begin
                    consume(_OF);
                    consume(_OBJECT);
                    include(pd.procoptions,po_methodpointer);
                  end;
                tt.def:=pd;
                { possible proc directives }
                if parseprocvardir then
                  begin
                    if check_proc_directive(true) then
                      begin
                         newtype:=ttypesym.create('unnamed',tt);
                         parse_var_proc_directives(tsym(newtype));
                         newtype.restype.def:=nil;
                         tt.def.typesym:=nil;
                         newtype.free;
                      end;
                    { Add implicit hidden parameters and function result }
                    handle_calling_convention(pd);
                  end;
              end;
            else
              expr_type;
         end;
         if tt.def=nil then
          tt:=generrortype;
      end;

end.
