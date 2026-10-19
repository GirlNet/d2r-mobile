#include "nvn_texture_bits.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { size_t start,length; } token;
typedef struct { size_t at,remove;const char *text; } edit;
static int equal(const char *s,token t,const char *word){return strlen(word)==t.length&&!memcmp(s+t.start,word,t.length);}
static int ident(const char *s,token t){return t.length&&(isalpha((unsigned char)s[t.start])||s[t.start]=='_');}
static int same(const char *s,token a,token b){return a.length==b.length&&!memcmp(s+a.start,s+b.start,a.length);}
static int failure(char *error,size_t size,const char *reason){if(error&&size)snprintf(error,size,"%s",reason);return -1;}
static int compare(const void *a,const void *b){const edit *x=a,*y=b;return x->at<y->at?-1:x->at>y->at?1:0;}
int nvn_texture_bits_source(const char *source,const uint8_t kinds[64],char **output,
                            uint64_t *applied,char *error,size_t error_size) {
    if(output)*output=NULL;if(applied)*applied=0;
    if(!source||!kinds||!output)return failure(error,error_size,"Invalid texture source arguments");
    uint64_t wanted=0;for(unsigned i=0;i<64;i++){if(kinds[i]>2)return failure(error,error_size,"Unknown texture numeric class");if(kinds[i])wanted|=UINT64_C(1)<<i;}
    size_t length=strlen(source);if(length>4*1024*1024)return failure(error,error_size,"Texture source too large");
    if(!wanted){*output=malloc(length+1);if(!*output)return failure(error,error_size,"Allocation failed");memcpy(*output,source,length+1);return 0;}
    token *tokens=malloc((length+1)*sizeof *tokens);edit *edits=malloc((length*2+64)*sizeof *edits);
    if(!tokens||!edits){free(tokens);free(edits);return failure(error,error_size,"Allocation failed");}
    size_t nt=0,ne=0;uint64_t found=0;token names[64]={{0}};size_t declarations[64]={0};const char *reason=NULL;
    for(size_t p=0;p<length;) {
        if(isspace((unsigned char)source[p])){p++;continue;}
        if(source[p]=='/'&&source[p+1]=='/'){while(p<length&&source[p]!='\n')p++;continue;}
        if(source[p]=='/'&&source[p+1]=='*'){const char *end=strstr(source+p+2,"*/");if(!end){reason="Unclosed comment";goto done;}p=(size_t)(end-source)+2;continue;}
        size_t start=p;
        if(source[p]=='\''||source[p]=='"') {
            char quote=source[p++];while(p<length&&source[p]!=quote){if(source[p]=='\\')p++;p++;}
            if(p>=length){reason="Unclosed literal";goto done;}p++;
        } else if(isalnum((unsigned char)source[p])||source[p]=='_') {
            do{p++;}while(isalnum((unsigned char)source[p])||source[p]=='_');
        } else p++;
        tokens[nt++]=(token){start,p-start};
    }
    for(size_t i=0;i+13<nt;i++) {
        if(!equal(source,tokens[i],"texture2d")&&!equal(source,tokens[i],"texture2d_array")&&
           !equal(source,tokens[i],"texture2d_ms")&&!equal(source,tokens[i],"texture2d_ms_array"))continue;
        const char *parts[]={"<","float",">",NULL,"[","[","id","(",NULL,")","]","]",";"};
        int valid=1;for(unsigned j=0;j<13;j++)if(parts[j]&&!equal(source,tokens[i+j+1],parts[j]))valid=0;
        if(!valid||!ident(source,tokens[i+4]))continue;
        token number=tokens[i+9];unsigned aid=0;
        for(size_t j=0;j<number.length;j++){unsigned digit=(unsigned char)source[number.start+j]-'0';if(digit>9||aid>63){valid=0;break;}aid=aid*10+digit;}
        if(!valid||aid>=64||!kinds[aid])continue;
        if(found&(UINT64_C(1)<<aid)){reason="Duplicate texture argument ID";goto done;}
        for(unsigned j=0;j<64;j++)if(names[j].length&&same(source,names[j],tokens[i+4])){reason="Duplicate texture member";goto done;}
        found|=UINT64_C(1)<<aid;names[aid]=tokens[i+4];declarations[aid]=i+4;
        edits[ne++]=(edit){tokens[i+2].start,tokens[i+2].length,kinds[aid]==1?"uint":"int"};
    }
    if(found!=wanted){reason="Missing supported float texture declaration";goto done;}
    for(size_t i=0;i<nt;i++)for(unsigned aid=0;aid<64;aid++) {
        if(!names[aid].length||!same(source,tokens[i],names[aid])||i==declarations[aid])continue;
        if(i<2||i+3>=nt||!ident(source,tokens[i-2])||!equal(source,tokens[i-1],".")||
           !equal(source,tokens[i+1],".")||!equal(source,tokens[i+3],"(")||
           (i>=3&&equal(source,tokens[i-3],"."))){reason="Unsupported texture member use";goto done;}
        int load=equal(source,tokens[i+2],"read"),query=0;
        const char *queries[]={"get_width","get_height","get_depth","get_array_size","get_num_mip_levels","get_num_samples"};
        for(unsigned q=0;q<sizeof queries/sizeof *queries;q++)query|=equal(source,tokens[i+2],queries[q]);
        if(!load&&!query){reason="Integer texture requires direct loads or dimension queries";goto done;}
        size_t end=i+3;unsigned depth=0;
        do{if(equal(source,tokens[end],"("))depth++;else if(equal(source,tokens[end],")"))depth--;end++;}while(end<nt&&depth);
        if(depth){reason="Unclosed texture call";goto done;}
        if(load){edits[ne++]=(edit){tokens[i-2].start,0,"as_type<float4>("};edits[ne++]=(edit){tokens[end-1].start+tokens[end-1].length,0,")"};}
    }
    qsort(edits,ne,sizeof *edits,compare);
    size_t capacity=length+1;for(size_t i=0;i<ne;i++)capacity+=strlen(edits[i].text);
    char *result=malloc(capacity);if(!result){reason="Allocation failed";goto done;}
    size_t from=0,to=0;
    for(size_t i=0;i<ne;i++) {
        edit e=edits[i];if(e.at<from){free(result);reason="Overlapping texture edits";goto done;}
        memcpy(result+to,source+from,e.at-from);to+=e.at-from;size_t n=strlen(e.text);memcpy(result+to,e.text,n);to+=n;from=e.at+e.remove;
    }
    memcpy(result+to,source+from,length-from+1);*output=result;if(applied)*applied=found;
done:
    free(tokens);free(edits);return reason?failure(error,error_size,reason):0;
}
