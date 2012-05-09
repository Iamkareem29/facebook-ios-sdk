/*
 * Copyright 2012 Facebook
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *    http://www.apache.org/licenses/LICENSE-2.0
 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FBGraphObjectPagingLoader.h"
#import "FBRequest.h"
#import "FBError.h"

@interface FBGraphObjectPagingLoader ()

@property (nonatomic, retain) NSString *nextLink;
@property (nonatomic, retain) FBRequestConnection *connection;

- (void)followNextLink;

@end


@implementation FBGraphObjectPagingLoader

@synthesize tableView = _tableView;
@synthesize dataSource = _dataSource;
@synthesize pagingMode = _pagingMode;
@synthesize nextLink = _nextLink;
@synthesize session = _session;
@synthesize connection = _connection;
@synthesize delegate = _delegate;

- (id)initWithDataSource:(FBGraphObjectTableDataSource*)aDataSource {
    if (self = [super init]) {
        self.dataSource = aDataSource;
        self.pagingMode = FBGraphObjectPagingModeAsNeeded;
    }
    return self;
}

- (void)setDataSource:(FBGraphObjectTableDataSource *)dataSource {
    [dataSource retain];
    [_dataSource release];
    _dataSource = dataSource;
    _dataSource.dataNeededDelegate = self;
}

- (void)setTableView:(UITableView*)tableView {
    [tableView retain];
    [_tableView release];
    _tableView = tableView;

    // If we already have a nextLink and we are in immediate paging mode, re-start
    // loading when we are reconnected to a table view.
    if (self.pagingMode == FBGraphObjectPagingModeImmediate &&
        self.nextLink &&
        self.tableView) {
        [self followNextLink];
    }
}

- (void)updateView
{
    [self.dataSource update];
    [self.tableView reloadData];
}

// Adds new results to the table and attempts to preserve visual context in the table
- (void)addResultsAndUpdateView:(NSDictionary*)results {
    NSArray *data = (NSArray *)[results objectForKey:@"data"];
    if (data.count == 0) {
        // If we got no data, stop following paging links.
        self.nextLink = nil;
        // Tell the data source we're done.
        [self.dataSource appendGraphObjects:nil];
        [self updateView];
        
        if ([self.delegate respondsToSelector:@selector(pagingLoader:didLoadData:)]) {
            [self.delegate pagingLoader:self didLoadData:results];
        }
        return;
    } else {
        NSDictionary *paging = (NSDictionary *)[results objectForKey:@"paging"];
        NSString *next = (NSString *)[paging objectForKey:@"next"];
        self.nextLink = next;
    }
    
    if (!self.dataSource.hasGraphObjects) {
        // If we don't have any data already, this is easy.
        [self.dataSource appendGraphObjects:data];
        [self updateView];
    } else {
        // As we fetch additional results and add them to the table, we do not
        // want the table jumping around seemingly at random, frustrating the user's
        // attempts at scrolling, etc. Since results may be added anywhere in 
        // the table, we choose to try to keep the first visible row in a fixed
        // position (from the user's perspective). We try to keep it positioned at
        // the same offset from the top of the screen so adding new items seems
        // smoother, as opposed to having it "snap" to a multiple of row height
        // (as would happen by simply calling [UITableView 
        // scrollToRowAtIndexPath:atScrollPosition:animated:].
        
        // Which object is currently at the top of the table (the "anchor" object)?
        // (If possible, we choose the second row, to give context above and below and avoid
        // cases where the first row is only barely visible, thus providing little context.)
        NSArray *visibleRowIndexPaths = [self.tableView indexPathsForVisibleRows];
        int anchorRowIndex = (visibleRowIndexPaths.count > 1) ? 1 : 0;
        NSIndexPath *anchorIndexPath = [visibleRowIndexPaths objectAtIndex:anchorRowIndex];
        id anchorObject = [self.dataSource itemAtIndexPath:anchorIndexPath];
        
        // What is its rect, and what is the overall contentOffset of the table?
        CGRect anchorRowRectBefore = [self.tableView rectForRowAtIndexPath:anchorIndexPath];
        CGPoint contentOffset = self.tableView.contentOffset;
        
        // Update with new data and reload the table.
        [self.dataSource appendGraphObjects:data];
        [self updateView];
        
        // Where is the anchor object now?
        anchorIndexPath = [self.dataSource indexPathForItem:anchorObject];
        CGRect anchorRowRectAfter = [self.tableView rectForRowAtIndexPath:anchorIndexPath];
        
        // Keep the content offset the same relative to the rect of the row (so if it was
        // 1/4 scrolled off the top before, it still will be, etc.)
        contentOffset.y += anchorRowRectAfter.origin.y - anchorRowRectBefore.origin.y;
        self.tableView.contentOffset = contentOffset;
    }

    if ([self.delegate respondsToSelector:@selector(pagingLoader:didLoadData:)]) {
        [self.delegate pagingLoader:self didLoadData:results];
    }
    
    // If we are supposed to keep paging, do so. But if we have lost our tableView,
    // take that as a sign to stop (probably because the view was unloaded). If 
    // tableView is re-set, we will start again.
    if (self.pagingMode == FBGraphObjectPagingModeImmediate &&
        self.tableView) {
        [self followNextLink];
    }
}

- (void)followNextLink {
    if (self.nextLink &&
        self.session) {
        [self.connection cancel];
        self.connection = nil;
        
        if ([self.delegate respondsToSelector:@selector(pagingLoader:willLoadURL:)]) {
            [self.delegate pagingLoader:self willLoadURL:self.nextLink];
        }
        
        FBRequest *request = [[FBRequest alloc] initWithSession:self.session
                                                      graphPath:nil];
        FBRequestConnection *connection = [request connectionWithCompletionHandler:^(FBRequestConnection *connection, id result, NSError *error) {
            self.connection = nil;
            [self requestCompleted:connection result:result error:error];
        }];
        [request release];
        
        // Override the URL using the one passed back in 'next'.
        NSURL *url = [NSURL URLWithString:self.nextLink];
        NSMutableURLRequest* urlRequest = [NSMutableURLRequest requestWithURL:url];
        connection.urlRequest = urlRequest;

        self.nextLink = nil;
        
        self.connection = connection;
        [self.connection start];
    }
}

- (void)startLoadingWithRequest:(FBRequest*)request {
    [self.dataSource clearGraphObjects];
    
     FBRequestConnection *connection = [request connectionWithCompletionHandler:
        ^(FBRequestConnection *connection, id result, NSError *error) {
            [self requestCompleted:connection result:result error:error];
        }];

    NSString *urlString = [[[connection urlRequest] URL] absoluteString];
    if ([self.delegate respondsToSelector:@selector(pagingLoader:willLoadURL:)]) {
        [self.delegate pagingLoader:self willLoadURL:urlString];
    }

    self.connection = connection;
    [self.connection start];
}

- (void)cancel {
    [self.connection cancel];
}

- (void)requestCompleted:(FBRequestConnection *)connection
                  result:(id)result
                   error:(NSError *)error {
    self.connection = nil;

    NSDictionary *resultDictionary = (NSDictionary *)result;
    
    NSArray *data = nil;    
    if (!error && [result isKindOfClass:[NSDictionary class]]) {
        id rawData = [resultDictionary objectForKey:@"data"];
        if ([rawData isKindOfClass:[NSArray class]]) {
            data = (NSArray *)rawData;
        }
    }

    if (!error && !data) {
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:result
                                                             forKey:FBErrorParsedJSONResponseKey];
        error = [[[NSError alloc] initWithDomain:FBiOSSDKDomain
                                            code:FBErrorProtocolMismatch
                                        userInfo:userInfo]
                 autorelease];
    } 
    
    if (error) {
        if ([self.delegate respondsToSelector:@selector(pagingLoader:handleError:)]) {
            [self.delegate pagingLoader:self handleError:error];
        }        
    } else {
        [self addResultsAndUpdateView:resultDictionary];        
    }
}

#pragma mark FBGraphObjectDataSourceDataNeededDelegate methods

- (void)graphObjectTableDataSourceNeedsData:(FBGraphObjectTableDataSource *)dataSource triggeredByIndexPath:(NSIndexPath*)indexPath {
    if (self.pagingMode == FBGraphObjectPagingModeAsNeeded) {
        [self followNextLink];
    }
}

#pragma mark -

@end
