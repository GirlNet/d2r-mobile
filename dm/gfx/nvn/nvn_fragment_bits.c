#include "nvn_fragment_bits.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *p; } cursor;
typedef struct { char type[64],name[64],attribute[64];int location; } field;
typedef struct { char *p;size_t used,size; } builder;
static void spaces(cursor *c){while(isspace((unsigned char)*c->p))c->p++;}
static int identifier(cursor *c,char out[64]) {
    spaces(c);const char *start=c->p;if(!isalpha((unsigned char)*start)&&*start!='_')return 0;
    while(isalnum((unsigned char)*c->p)||*c->p=='_')c->p++;
    size_t n=(size_t)(c->p-start);if(n>=64)return 0;memcpy(out,start,n);out[n]=0;return 1;
}
static int literal(cursor *c,const char *text){spaces(c);size_t n=strlen(text);if(strncmp(c->p,text,n))return 0;c->p+=n;return 1;}
static int append(builder *b,const char *text,size_t n){if(n>=b->size-b->used)return 0;memcpy(b->p+b->used,text,n);b->used+=n;b->p[b->used]=0;return 1;}
static int format(builder *b,const char *text,...) {
    va_list args;va_start(args,text);int n=vsnprintf(b->p+b->used,b->size-b->used,text,args);va_end(args);
    if(n<0||(size_t)n>=b->size-b->used)return 0;b->used+=(size_t)n;return 1;
}
static int fail(char *error,size_t size,const char *message){if(error&&size)snprintf(error,size,"%s",message);return -1;}
static int copy_source(const char *source,char **output) {
    size_t n=strlen(source)+1;*output=malloc(n);if(!*output)return -1;memcpy(*output,source,n);return 0;
}
// Skip comments and quoted literals before examining braces or return tokens.
static const char *skip_literal(const char *p) {
    if(p[0]=='/'&&p[1]=='/'){while(*p&&*p!='\n')p++;return p;}
    if(p[0]=='/'&&p[1]=='*'){p=strstr(p+2,"*/");return p?p+2:NULL;}
    if(*p=='"'||*p=='\''){char quote=*p++;while(*p&&*p!=quote){if(*p=='\\'){p++;if(!*p)return NULL;}p++;}return *p?p+1:NULL;}
    return p;
}
int nvn_fragment_bits_source(const char *source,const uint8_t kinds[8],char **output,
                             uint16_t *applied,char *error,size_t error_size) {
    if(output)*output=NULL;if(applied)*applied=0;
    if(!source||!kinds||!output)return fail(error,error_size,"Invalid fragment source arguments");
    int any=0;for(unsigned i=0;i<8;i++){if(kinds[i]>2)return fail(error,error_size,"Unknown fragment output class");any|=kinds[i];}
    if(!any)return copy_source(source,output);
    const char *entry=strstr(source,"fragment ");
    if(!entry||strstr(entry+9,"fragment ")||strstr(source,"DMFragmentBits_")||strstr(source,"dm_fragment_bits"))
        return fail(error,error_size,"Missing, ambiguous or already specialized fragment entry");
    cursor header={entry+9};char type[64];spaces(&header);const char *type_start=header.p;
    if(!identifier(&header,type))return fail(error,error_size,"Missing fragment return type");
    const char *type_end=header.p,*body=strchr(type_end,'{');
    if(!body)return fail(error,error_size,"Missing fragment body");
    // A fragment stage with no exports needs no color specialization.
    if(!strcmp(type,"void"))return copy_source(source,output);
    cursor structure={NULL};const char *search=source;
    while((search=strstr(search,"struct"))&&search<entry) {
        cursor c={search+6};char name[64];search+=6;
        if(identifier(&c,name)&&!strcmp(name,type)&&literal(&c,"{")){
            if(structure.p)return fail(error,error_size,"Duplicate output structure");structure=c;
        }
    }
    if(!structure.p)return fail(error,error_size,"Missing flat fragment output structure");
    field fields[10];unsigned count=0,seen=0,depth=0,sample=0;uint16_t mask=0;
    for(;;) {
        spaces(&structure);if(*structure.p=='}'){structure.p++;if(!literal(&structure,";"))return fail(error,error_size,"Invalid output structure end");break;}
        if(count==10)return fail(error,error_size,"Too many fragment outputs");field *f=&fields[count];f->location=-1;
        if(!identifier(&structure,f->type)||!identifier(&structure,f->name)||!literal(&structure,"[["))return fail(error,error_size,"Unsupported output declaration");
        const char *attribute=structure.p,*end=strstr(attribute,"]]");
        if(!end||(size_t)(end-attribute)>=sizeof f->attribute)return fail(error,error_size,"Invalid output attribute");
        memcpy(f->attribute,attribute,(size_t)(end-attribute));f->attribute[end-attribute]=0;
        structure.p=end+2;if(!literal(&structure,";"))return fail(error,error_size,"Invalid output declaration end");
        cursor a={attribute};
        if(literal(&a,"color(")) {
            spaces(&a);if(!isdigit((unsigned char)*a.p))return fail(error,error_size,"Invalid color location");
            unsigned n=0;while(isdigit((unsigned char)*a.p)){n=n*10+(unsigned)(*a.p++-'0');if(n>=8)return fail(error,error_size,"Color location outside host limits");}
            if(!literal(&a,")")||a.p!=end||(seen&(1u<<n))||strncmp(f->type,"float",5)||
               (f->type[5]&&((f->type[5]<'2'||f->type[5]>'4')||f->type[6])))return fail(error,error_size,"Duplicate or unsupported color export");
            seen|=1u<<n;f->location=(int)n;mask|=(uint16_t)kinds[n]<<(2*n);
        } else if(!strcmp(f->attribute,"depth(any)")||!strcmp(f->attribute,"depth(less)")||!strcmp(f->attribute,"depth(greater)")) {
            if(depth++||strcmp(f->type,"float"))return fail(error,error_size,"Invalid depth export");
        } else if(!strcmp(f->attribute,"sample_mask")) {
            if(sample++||strcmp(f->type,"uint"))return fail(error,error_size,"Invalid sample mask export");
        } else return fail(error,error_size,"Unsupported fragment output attribute");
        for(unsigned i=0;i<count;i++)if(!strcmp(fields[i].name,f->name))return fail(error,error_size,"Duplicate output name");count++;
    }
    if(!mask)return copy_source(source,output);
    size_t length=strlen(source);if(length>SIZE_MAX/2-16384)return fail(error,error_size,"Fragment source too large");
    builder b={malloc(length*2+16384),0,length*2+16384};if(!b.p)return fail(error,error_size,"Fragment source allocation failed");
    int ok=append(&b,source,(size_t)(entry-source))&&format(&b,"struct DMFragmentBits_%s\n{\n",type);
    for(unsigned i=0;i<count&&ok;i++) {
        field *f=&fields[i];unsigned kind=f->location<0?0:kinds[f->location];
        ok=kind?format(&b,"    %s%s %s [[%s]];\n",kind==1?"uint":"int",f->type+5,f->name,f->attribute)
               :format(&b,"    %s %s [[%s]];\n",f->type,f->name,f->attribute);
    }
    ok=ok&&format(&b,"};\ninline DMFragmentBits_%s dm_fragment_bits(%s value)\n{\n    DMFragmentBits_%s converted = {};\n",type,type,type);
    for(unsigned i=0;i<count&&ok;i++) {
        field *f=&fields[i];unsigned kind=f->location<0?0:kinds[f->location];
        ok=kind?format(&b,"    converted.%s = as_type<%s%s>(value.%s);\n",f->name,kind==1?"uint":"int",f->type+5,f->name)
               :format(&b,"    converted.%s = value.%s;\n",f->name,f->name);
    }
    const char *finish="    return converted;\n}\n";
    ok=ok&&append(&b,finish,strlen(finish))&&append(&b,entry,(size_t)(type_start-entry))
        &&format(&b,"DMFragmentBits_%s",type)&&append(&b,type_end,(size_t)(body+1-type_end));
    const char *p=body+1,*chunk=p;unsigned nesting=1,returns=0;
    while(ok&&*p&&nesting) {
        const char *next=skip_literal(p);if(!next){ok=0;break;}if(next!=p){p=next;continue;}
        if(*p=='{')nesting++;else if(*p=='}')nesting--;
        if(!strncmp(p,"return",6)&&(p==body+1||(!isalnum((unsigned char)p[-1])&&p[-1]!='_'))&&!isalnum((unsigned char)p[6])&&p[6]!='_') {
            cursor c={p+6};char value[64];
            if(!identifier(&c,value)||!literal(&c,";")){ok=0;break;}
            ok=append(&b,chunk,(size_t)(p-chunk))&&format(&b,"return dm_fragment_bits(%s);",value);
            p=c.p;chunk=p;returns++;continue;
        }
        p++;
    }
    ok=ok&&!nesting&&returns&&append(&b,chunk,strlen(chunk));
    if(!ok){free(b.p);return fail(error,error_size,"Unsupported fragment body or output bounds");}
    *output=b.p;if(applied)*applied=mask;return 0;
}
