#include "nvn_vertex_bits.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *p; } cursor;
typedef struct { char type[64],name[64];unsigned location; } field;
typedef struct { char *p;size_t used,size; } builder;
static void spaces(cursor *c){while(isspace((unsigned char)*c->p))c->p++;}
static int identifier(cursor *c,char out[64]) {
    spaces(c);const char *start=c->p;
    if(!isalpha((unsigned char)*start)&&*start!='_')return 0;
    while(isalnum((unsigned char)*c->p)||*c->p=='_')c->p++;
    size_t n=(size_t)(c->p-start);if(n>=64)return 0;memcpy(out,start,n);out[n]=0;return 1;
}
static int literal(cursor *c,const char *text){spaces(c);size_t n=strlen(text);if(strncmp(c->p,text,n))return 0;c->p+=n;return 1;}
static int previous(const char *source,const char **position,char out[64],const char **end) {
    const char *p=*position;while(p>source&&isspace((unsigned char)p[-1]))p--;*end=p;
    while(p>source&&(isalnum((unsigned char)p[-1])||p[-1]=='_'))p--;
    size_t n=(size_t)(*end-p);if(!n||n>=64)return 0;memcpy(out,p,n);out[n]=0;*position=p;return 1;
}
static int append(builder *b,const char *text,size_t n){if(n>=b->size-b->used)return 0;memcpy(b->p+b->used,text,n);b->used+=n;b->p[b->used]=0;return 1;}
static int format(builder *b,const char *text,...) {
    va_list args;va_start(args,text);int n=vsnprintf(b->p+b->used,b->size-b->used,text,args);va_end(args);
    if(n<0||(size_t)n>=b->size-b->used)return 0;b->used+=(size_t)n;return 1;
}
static int fail(char *error,size_t size,const char *message){if(error&&size)snprintf(error,size,"%s",message);return -1;}
static int copy_source(const char *source,char **output) {
    size_t n=strlen(source)+1;*output=malloc(n);if(!*output)return -1;memcpy(*output,source,n);return 0;
}
int nvn_vertex_bits_source(const char *source,const uint8_t kinds[16],char **output,
                           uint32_t *applied,char *error,size_t error_size) {
    if(output)*output=NULL;if(applied)*applied=0;
    if(!source||!kinds||!output)return fail(error,error_size,"Invalid vertex source arguments");
    int any=0;for(unsigned i=0;i<16;i++){if(kinds[i]>2)return fail(error,error_size,"Unknown vertex input class");any|=kinds[i];}
    if(!any)return copy_source(source,output);
    const char *entry=strstr(source,"vertex ");
    if(!entry||strstr(entry+7,"vertex "))return fail(error,error_size,"Missing or ambiguous vertex entry");
    const char *body=strchr(entry,'{'),*stage=strstr(entry,"[[stage_in]]");
    if(!body)return fail(error,error_size,"Missing vertex entry body");
    if(!stage||stage>body)return copy_source(source,output);
    const char *second=strstr(stage+1,"[[stage_in]]");
    if((second&&second<body)||strstr(source,"dm_raw_vertex")||strstr(source,"DMVertexBits_"))
        return fail(error,error_size,"Ambiguous or already specialized vertex source");
    char variable[64],type[64];const char *variable_end,*type_end,*parameter=stage;
    if(!previous(source,&parameter,variable,&variable_end)||!previous(source,&parameter,type,&type_end))
        return fail(error,error_size,"Unsupported stage input parameter");
    cursor structure={NULL};const char *search=source;
    while((search=strstr(search,"struct"))) {
        cursor c={search+6};char name[64];search+=6;
        if(identifier(&c,name)&&!strcmp(name,type)&&literal(&c,"{")){
            if(structure.p)return fail(error,error_size,"Duplicate input structure");structure=c;
        }
    }
    if(!structure.p)return fail(error,error_size,"Missing input structure");
    field fields[16];unsigned count=0,seen=0;uint32_t mask=0;
    for(;;){
        spaces(&structure);if(*structure.p=='}'){structure.p++;if(!literal(&structure,";"))return fail(error,error_size,"Invalid input structure end");break;}
        if(count==16)return fail(error,error_size,"Too many vertex inputs");field *f=&fields[count];
        if(!identifier(&structure,f->type)||strncmp(f->type,"float",5)||
           (f->type[5]&&((f->type[5]<'2'||f->type[5]>'4')||f->type[6]))||
           !identifier(&structure,f->name)||!literal(&structure,"[[attribute("))
            return fail(error,error_size,"Unsupported vertex input declaration");
        spaces(&structure);if(!isdigit((unsigned char)*structure.p))return fail(error,error_size,"Invalid attribute location");
        unsigned location=0;while(isdigit((unsigned char)*structure.p)){location=location*10+(unsigned)(*structure.p++-'0');if(location>=16)return fail(error,error_size,"Attribute location outside host limits");}
        if(!literal(&structure,")]]")||!literal(&structure,";")||(seen&(1u<<location)))return fail(error,error_size,"Duplicate or invalid attribute");
        for(unsigned i=0;i<count;i++)if(!strcmp(fields[i].name,f->name))return fail(error,error_size,"Duplicate attribute name");
        f->location=location;seen|=1u<<location;mask|=(uint32_t)kinds[location]<<(2*location);count++;
    }
    if(!mask)return copy_source(source,output);
    size_t length=strlen(source);if(length>SIZE_MAX-16384)return fail(error,error_size,"Vertex source too large");
    builder b={malloc(length+16384),0,length+16384};if(!b.p)return fail(error,error_size,"Vertex source allocation failed");
    int ok=append(&b,source,(size_t)(entry-source))&&format(&b,"struct DMVertexBits_%s\n{\n",type);
    for(unsigned i=0;i<count&&ok;i++) {
        field *f=&fields[i];const char *base=kinds[f->location]==1?"uint":kinds[f->location]==2?"int":"float";
        ok=format(&b,"    %s%s %s [[attribute(%u)]];\n",base,f->type+5,f->name,f->location);
    }
    ok=ok&&append(&b,"};\n",3)&&append(&b,entry,(size_t)(parameter-entry))&&format(&b,"DMVertexBits_%s dm_raw_vertex",type)
        &&append(&b,variable_end,(size_t)(body+1-variable_end))&&format(&b,"\n    %s %s = {};\n",type,variable);
    for(unsigned i=0;i<count&&ok;i++) {
        field *f=&fields[i];ok=kinds[f->location]
            ?format(&b,"    %s.%s = as_type<%s>(dm_raw_vertex.%s);\n",variable,f->name,f->type,f->name)
            :format(&b,"    %s.%s = dm_raw_vertex.%s;\n",variable,f->name,f->name);
    }
    ok=ok&&append(&b,body+1,strlen(body+1));
    if(!ok){free(b.p);return fail(error,error_size,"Vertex specialization exceeds bounds");}
    *output=b.p;if(applied)*applied=mask;return 0;
}
