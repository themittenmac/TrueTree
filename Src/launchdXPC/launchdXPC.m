//
//  launchdXPC.c
//  Created by Patrick Wardle
//  Ported from code by Jonathan Levin
//

#include <stdio.h>
#import "launchdXPC.h"
#import <Foundation/Foundation.h>


#define ROUTINE_DUMP_PROCESS    0x2c4    // 708

extern char *xpc_strerror (int);

NSMutableDictionary* parse(NSString* data);

//hit up launchd (via XPC) to get process info
NSDictionary* getProcessInfo(unsigned long pid)
{
    //proc info
    NSDictionary* processInfo = nil;
    
    //xpc dictionary
    // passed to launchd to get proc info
    xpc_object_t procInfoRequest = NULL;
    
    //xpc (out) dictionary
    // don't really contain response, but will have (any) errors
    xpc_object_t __autoreleasing response = NULL;
    
    //pipe to file descriptors
    // launchd expects a writeable fd for 'passing back' data
    NSPipe *pipe = nil;
    
    //(xpc) error
    int64_t xpcError = 0;
    
    //global data
    struct xpc_global_data* globalData = NULL;
    
    //init dictionary
    procInfoRequest = xpc_dictionary_create(NULL,NULL,0);

    //init pipe
    pipe = [NSPipe pipe];

    //specify xpc routine
    // 0x2c4 is what dumps the process info
    xpc_dictionary_set_uint64(procInfoRequest, "routine", ROUTINE_DUMP_PROCESS);
    
    //specify xpc subsystem
    xpc_dictionary_set_uint64 (procInfoRequest, "subsystem", 2);

    //specify the file descriptor
    xpc_dictionary_set_fd(procInfoRequest, "fd", pipe.fileHandleForWriting.fileDescriptor);

    //specify (targert) process id
    xpc_dictionary_set_int64(procInfoRequest, "pid", pid);
    
    //grab from
    globalData  = (struct xpc_global_data *) _os_alloc_once_table[1].ptr;

    //request process info
    if(0 != xpc_pipe_routine((__bridge xpc_pipe_t)(globalData->xpc_bootstrap_pipe), procInfoRequest, &response))
    {
        //error
        goto bail;
    }
    
    //check for other error
    xpcError = xpc_dictionary_get_int64(response, "error");
    if(0 != xpcError)
    {
        //error
        goto bail;
    }
    
    //parse
    processInfo = parse([[NSString alloc] initWithData:[pipe.fileHandleForReading availableData] encoding:NSUTF8StringEncoding]);
    
bail:
    
    return processInfo;
}


//parse proc info
NSMutableDictionary* parse(NSString* data)
{
    //parsed proc info
    NSMutableDictionary* procInfo = nil;
    
    //lines
    NSArray* lines = nil;
    
    //dictionaries
    NSMutableArray* dictionaries = nil;
    
    //alloc
    procInfo = [[NSMutableDictionary alloc] init];
    
    //pool
    @autoreleasepool {
       
    //alloc
    dictionaries = [NSMutableArray array];
    
    //split
    lines = [data componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
   
    //start w/ top level
    [dictionaries addObject:procInfo];
    
    //process 'dictionary'
    [lines enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
        //key
        NSString* key = nil;
        
        //tokens
        NSArray* tokens = nil;
        
        //obj should be a string
        if(YES != [obj isKindOfClass:[NSString class]]) return;
        
        //skip first line
        if(0 == idx) return;
        
        //trim object
        obj = [obj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        //skip empty/blank lines
        if(0 == [obj length]) return;
            
        //key line? (line: "key = {")
        // extract key and add new dictionary
        if(YES == [obj hasSuffix:@"{"])
        {
            //tokenize
            tokens = [obj componentsSeparatedByString:@"="];
            
            //extract key
            // everything before '='
            key = tokens.firstObject;
            if(0 == key.length) return;
            
            //init new dictionary
            dictionaries.lastObject[key] = [NSMutableDictionary dictionary];
            
            //'save' new dictionary
            [dictionaries addObject:dictionaries.lastObject[key]];
            
            return;
        }
        
        //end key line? (line: "}")
        // remove dictionary, as it's no longer needed
        if(YES == [obj hasSuffix:@"}"])
        {
            //remove
            [dictionaries removeLastObject];
            
            return;
        }
        
        //line w/ '=>' separator?
        // (line: "key => value")
        if(NSNotFound != [obj rangeOfString:@" => "].location)
        {
            //tokenize
            tokens = [obj componentsSeparatedByString:@" => "];
            
            //key is first value
            key = tokens.firstObject;
            if(0 == key.length) return;
                
            //add key/value pair
            dictionaries.lastObject[key] = tokens.lastObject;
            
            return;
        }
        
        //line w/ '=' separator?
        // (line: "key = value")
        if(NSNotFound != [obj rangeOfString:@" = "].location)
        {
            //tokenize
            tokens = [obj componentsSeparatedByString:@" = "];
            
            //key is first value
            key = tokens.firstObject;
            if(0 == key.length) return;
                
            //add key/value pair
            dictionaries.lastObject[key] = tokens.lastObject;
            
            return;
        }
        
        //non-key:value line in embedded dictionary?
        if( (dictionaries.lastObject != procInfo) &&
            (NSNotFound == [obj rangeOfString:@" = "].location) )
        {
            //add key/value pair
            dictionaries.lastObject[[NSNumber numberWithInteger:[dictionaries.lastObject count]]] = obj;
            
            return;
        }
    
    }];
        
    } //pool

    return procInfo;
}
